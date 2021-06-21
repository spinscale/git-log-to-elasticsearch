# git-log-to-elasticsearch

## Usage

Make sure [crystal](https://crystal-lang.org/install/) is installed (tested
with Crystal 1.0.0)


```bash
shards update
shards build git-log-to-elasticsearch --production
# this only imports the main branch
./bin/git-log-to-elasticsearch -v -b '^origin/main$' \
  -n 'org/my-repo-name' v ~/path/to/repo
```

Possible arguments:

* `--host=URL`: Target URL to index into, default `http://localhost:9200`
* `-b regex, --branch=regex`: specifies the branches to import as regex, default `.*` (all branches)
* `-u, --user=user:pass`: basic auth info
* `-n NAME, --name=NAME`: specifies the repo name, i.e. `elastic/elasticsearch`
* `-v, --verbose`: Verbose output
* `-d, --dry-run`: Don't index into Elasticsearch, exit before

Sample run to index only the master branch data of my local Elasticsearch repo
in one of my Elastic Cloud clusters

```
./bin/git-log-to-elasticsearch -b '^origin/master$' -n 'elastic/elasticsearch' \
  --host https://vega-demo.es.europe-west3.gcp.cloud.es.io:9243 \
  -u elastic:$PASS ~/devel/elasticsearch/
```

This takes a couple of minutes. I have not yet taken the time to parallelize
this using fibers and multi threading. Feel free to send a PR.

## Contributing

1. Fork it (<https://github.com/spinscale/git-log-to-elasticsearch/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Alexander Reelsen](https://github.com/spinscale) - creator and maintainer
