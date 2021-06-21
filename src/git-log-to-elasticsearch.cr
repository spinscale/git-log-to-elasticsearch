require "git"
require "colorize"
require "option_parser"
require "json"
require "http/client"
require "progress_bar.cr/progress_bar"
require "base64"

index_mapping_json = %q(
  {
    "settings": {
      "index" : {
        "refresh_interval" : "30s",
        "sort.field" : "@timestamp",
        "sort.order" : "desc"
      },
      "analysis": {
        "analyzer": {
          "email_analyzer": {
            "tokenizer": "email_tokenizer"
          }
        },
        "tokenizer": {
          "email_tokenizer": {
            "type": "uax_url_email"
          }
        }
      }
    },
    "mappings": {
      "runtime": {
        "hour_of_day": {
          "type": "long",
          "script": {
            "source": "emit(doc['@timestamp'].value.hour)"
          }
        }
      },
      "properties": {
        "sha": {
          "type": "keyword"
        },
        "repo": {
          "type": "text",
          "fields": {
            "raw": {
              "type": "keyword"
            }
          }
        },
        "@timestamp": {
          "type": "date"
        },
        "branch": {
          "type": "keyword"
        },
        "message": {
          "type": "text"
        },
        "files": {
          "type" : "object",
          "properties" : {
            "added" :    { "type" : "keyword" },
            "deleted" :  { "type" : "keyword" },
            "modified" : { "type" : "keyword" },
            "all" :      { "type" : "keyword" }
          }
        },
        "author": {
          "type": "object",
          "properties": {
            "name": {
              "type": "text",
              "fields": {
                "raw": {
                  "type": "keyword"
                }
              }
            },
            "email": {
              "type": "text",
              "analyzer": "email_analyzer",
              "fields": {
                "raw": {
                  "type": "keyword"
                }
              }
            },
            "time": {
              "type": "date"
            }
          }
        },
        "committer": {
          "type": "object",
          "properties": {
            "name": {
              "type": "text",
              "fields": {
                "raw": {
                  "type": "keyword"
                }
              }
            },
            "email": {
              "type": "text",
              "analyzer": "email_analyzer",
              "fields": {
                "raw": {
                  "type": "keyword"
                }
              }
            },
            "time": {
              "type": "date"
            }
          }
        }
      }
    }
  }
)

module Git::Log::To::Elasticsearch
  VERSION = "0.1.0"
  NAME = "git-log-to-elasticsearch"

  url = "http://localhost:9200"
  index = "commits"
  # a good elasticsearch filter would be '\\d+\.\\d+|master'
  branch_regex = Regex.new(".*")
  dryrun = false
  verbose = false
  repo_name : String|Nil
  repo_name = ""
  path : String|Nil
  auth = ""

  OptionParser.parse do |parser|
    parser.banner = "Usage: #{NAME} [arguments] /path/to/repo"
    parser.on("-b regex", "--branch=regex", "Specifies the branches to import as regex, default [.*]") { |regex| branch_regex = Regex.new(regex) }
    parser.on("--host=URL", "url [default: http://localhost:9200]") { |h| url = h }
    parser.on("-u", "--user=user:pass", "basic auth info") { |a| auth = a }
    parser.on("-n NAME", "--name=NAME", "Specifies the repo name, i.e. [elastic/elasticsearch]") { |r| repo_name = r }
    parser.on("-v", "--verbose", "Verbose output") { verbose = true }
    parser.on("-d", "--dry-run", "Don't index into Elasticsearch") { dryrun = true }
    parser.on("-h", "--help", "Show this help") { puts parser ; exit 1 }
    parser.invalid_option do |flag|
      STDERR.puts "ERROR: #{flag} is not a valid option."
      STDERR.puts parser
      exit(1)
    end
  end

  path = ARGV[0]
  if path.empty?
    raise "path is required"
  end

  if repo_name.empty?
    raise "repo is required"
  end

  repo = Git::Repo.open(path)
  print "Filtering branches ... "
  branches = repo.branches.each_name(Git::BranchType::Remote).to_a
    # remove head
    .reject { |branch| branch.ends_with?("/HEAD") }
    .select { |branch| branch_regex.match(branch) }
    .sort

  print "found #{branches.size.colorize(:green)}\n"
  if verbose
    print "Branches: #{branches}\n"
  end

  print "Collecting commits in memory across #{branches.size.colorize(:green)} branches\n"
  commits = Hash(String, IndexableCommit).new

  total_commits = 0

  elapsed_time = Time.measure do
    branches.each do |branch|
      branch_name = branch.split('/', 2)[1]
      branch_commit_count = 0
      processed_commit_count = Atomic.new(0)

      begin
        repo.walk(repo.branches[branch].target_id) do |commit|
          branch_commit_count = branch_commit_count + 1
          total_commits = total_commits + 1

          if commits.has_key?(commit.sha)
            commits[commit.sha].branches << branch_name
          else
            indexable_commit = IndexableCommit.new(commit, branch_name, repo_name)
            commits[commit.sha] = indexable_commit
            if commit.parent_count > 0
              # this is the most expensive call, slowing everything down
              # also with fibers this did not get considerably faster
              diff = commit.diff
              diff.deltas.each do |delta|
                path = delta.new_file.path
                case delta.status
                when Git::DeltaType::Modified
                 indexable_commit.files_modified << path
                when Git::DeltaType::Added
                 indexable_commit.files_added << path
                when Git::DeltaType::Deleted
                 indexable_commit.files_deleted << path
                end
              end
              processed_commit_count.add 1
              if processed_commit_count.get % 100 == 0
                print ".".colorize(:green)
              end
            end
          end
        end
      rescue ex : Git::Error
        print "Git error when collecting branch #{branch}: #{ex.message}"
        print ex.backtrace
        # error on processing means total exit for us
        exit
      end
    end
  end

  print "\nTotal commits to index "
  print "#{commits.size}".colorize(:green)
  checked_commits_per_second = (total_commits/elapsed_time.total_seconds).to_i
  print " (checked #{checked_commits_per_second}/s, total #{total_commits})"
  print "\n"

  if dryrun
    print "Exiting due to dryrun.\n".colorize(:cyan)
    exit(0)
  end

  # create index with mapping (with index sorting)
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  if !auth.empty?
    headers["Authorization"] = "Basic " + Base64.strict_encode auth
  end

  response = HTTP::Client.get(url + "/" + index, headers: headers)
  if response.status_code == 404
    print "Creating index [#{index}] ... "
    response = HTTP::Client.put(url + "/" + index, headers: headers, body: index_mapping_json)
    if response.status_code == 200
      print "success\n".colorize(:green)
    else
      print "failed\n".colorize(:red)
      p response.body
      exit (-1)
    end
  else
    print "Index already created... skipping\n"
  end

  max_document_count = 5000
  current_document_count = 0
  # 500 bytes per document is still small, but helps setting a solid base size
  # to prevent initial resizing
  body = String::Builder.new max_document_count * 500
  print "Writing documents...\n"
  ticks = (commits.size/max_document_count)+1
  progress_bar = ProgressBar.new(total = ticks.to_i32)

  commits.each_value do |commit|
    body << %Q({ "index" : { "_id" : "#{commit._id}" } }\n)
    body << commit.to_json + "\n"
    current_document_count = current_document_count + 1

    if current_document_count >= max_document_count
      response = HTTP::Client.put(url + "/" + index + "/_bulk", headers: headers, body: body.to_s)
      body = String::Builder.new max_document_count * 500
      current_document_count = 0
      progress_bar.tick
    end
  end

  response = HTTP::Client.put(url + "/" + index + "/_bulk", headers: headers, body: body.to_s)
  progress_bar.tick
  progress_bar.complete
  print "Refreshing... "
  response = HTTP::Client.post(url + "/" + index + "/_refresh", headers: headers)
  print "ok\n".colorize(:green)

  print "Counting total documents in #{index}... "
  response = HTTP::Client.post(url + "/" + index + "/_count", headers: headers)
  document_count = JSON.parse(response.body)["count"].as_i.to_s
  print "#{document_count.colorize(:green)}\n"
end


# helper class to be able to index a commit as JSON document
class IndexableCommit

  property branches
  property files_added
  property files_modified
  property files_deleted
  getter _id : String

  def initialize(@commit : Git::Commit, branch : String, @repo : String)
    @branches = [ branch ]
    @files_added = [] of String
    @files_deleted = [] of String
    @files_modified = [] of String
    @_id = @repo.gsub('/', '-') + "-" + @commit.sha
  end

  def to_json(json : JSON::Builder)
    json.object do
      json.field "sha", @commit.sha
      json.field "repo", @repo
      json.field "@timestamp", @commit.time
      json.field "branch", @branches
      json.field "message", @commit.message
      json.field "author" do
        json.object do
            json.field "name", @commit.author.name
            json.field "email", @commit.author.email
            json.field "time", @commit.author.time
        end
      end
      json.field "committer" do
        json.object do
            json.field "name", @commit.committer.name
            json.field "email", @commit.committer.email
            json.field "time", @commit.committer.time
        end
      end

      json.field "files" do
        json.object do
          json.field "added", files_added
          json.field "modified", files_modified
          json.field "deleted", files_deleted
          json.field "all", files_added + files_modified + files_deleted
        end
      end
    end
  end
end
