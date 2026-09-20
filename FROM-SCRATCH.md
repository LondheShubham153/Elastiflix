# Elastic Stack, From Scratch

`./start.sh` in this repo builds the whole thing for you: Elasticsearch, Logstash,
Beats, Kibana, and the Elastiflix app, wired together in Docker. That's the right
way to run the demo. This document is for the other case: you want to do every
step by hand, on a plain Ubuntu machine, with no Docker at all, so you actually
understand what each command is doing.

Same four components, same movie catalogue, same end result: a search app backed
by Elasticsearch, with its own logs and metrics flowing back into Kibana. Nothing
here is simplified for teaching. It's the real install path, using the current
Elastic APT repository (9.x, currently resolving to 9.4.1).

One real difference from the Docker demo: a plain `apt install` of Elasticsearch
ships with security turned on by default. The Docker demo disables it on purpose,
to remove passwords and certificates as things that can break mid-lesson. Doing
this by hand means dealing with that security layer for real, which is worth
seeing at least once.

## What the Elastic Stack actually is, and why it exists

Start with the problem, not the product. A relational database answers "which
rows match this exact condition". Search is a different question: "out of
everything, what's most relevant to what the user typed". Ask a SQL database
to search 7,000 movie titles for "matrix" with a `LIKE '%matrix%'`, and the
leading wildcard kills the index; it scans every row, every time. It won't
rank "The Matrix" above a movie that mentions the word once in its plot. It
won't match "matrix" against "matrices". A search engine exists to answer that
different question well: rank results by relevance, tolerate typos and word
forms, and do it in milliseconds over millions of documents.

Elasticsearch does this with an inverted index, the same trick as the index at
the back of a textbook. You don't read the whole book to find "mitochondria",
you look the word up and it tells you which pages. Elasticsearch builds that
lookup for every field in every document you give it, which is why the same
engine that powers a movie search box also powers Wikipedia's search and
GitHub's code search.

That covers finding things. The other half of the problem is knowing what your
own systems are doing, usually called observability: logs, metrics and traces
from your services, centralized somewhere you can search and chart them. This
matters because the alternative is SSH-ing into a server and grepping a log
file while production is down, one machine at a time, hoping the problem
happened on the box you're currently looking at. Once you have more than a
handful of services, that stops being viable. Observability is the practice of
shipping everything to one searchable place before you need it, not after.

It turns out both problems, search and observability, need the same
underlying engine: something that can ingest huge volumes of semi-structured
data and answer "find me the interesting ones" fast. That's the whole reason
Elasticsearch ended up at the center of both. The rest of the stack grew
around getting data in and looking at it once it's there:

- **Logstash** takes data from wherever it lives and reshapes it into
  something worth querying: parsing a log line into fields, converting types,
  dropping noise, enriching records with values that aren't in the source.
- **Beats** are small, single-purpose agents that sit on the thing being
  watched (a server, a container) and ship data out. Filebeat tails logs,
  Metricbeat reads CPU and memory. They're deliberately dumb, because you can
  run a lightweight Beat on five hundred machines in a way you can't run five
  hundred copies of a JVM.
- **Kibana** is the window into all of it: search and filter raw documents in
  Discover, run raw queries against the API in Dev Tools, and build the charts
  and dashboards that turn "we have the data somewhere" into "here's what's
  actually happening right now".

This is why the stack shows up in so many unrelated-looking places: centralized
logging for a fleet of services, security teams building a SIEM to hunt
threats across the same log data, SRE teams doing observability by joining
logs, metrics and traces together, and product search, which is what
Elasticsearch was built for in the first place. Learn these four components
once, and you can read any of those setups, because they're all the same four
boxes wired differently.

Elastiflix, the app this repo builds, is a small demonstration of that
overlap on purpose: it's a movie search app that uses Elasticsearch to answer
searches, and its own logs and metrics are shipped right back into the same
cluster and watched through the same Kibana. The thing being searched and the
thing being observed are the same system.

## Before you start

- Ubuntu 22.04 or 24.04, a fresh VM or bare metal is fine
- At least 4 GB RAM free (8 GB is comfortable), 10 GB free disk
- `curl`, `python3`, `git` installed
- Node.js 18+ if you also want to run the Elastiflix app itself (optional; you
  can do everything up through Kibana dashboards without it)

Everything below assumes commands run as a regular user with `sudo`.

## 1. Elasticsearch

Add Elastic's package repository and install:

```bash
sudo apt update
sudo apt install -y apt-transport-https gnupg curl

curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  sudo gpg --dearmor -o /usr/share/keyrings/elastic.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | \
  sudo tee /etc/apt/sources.list.d/elastic-9.x.list

sudo apt update
sudo apt install -y elasticsearch
```

The install prints an `elastic` superuser password once, to the terminal —
but only if the package's postinstall script actually starts and
auto-configures Elasticsearch on the spot. On some systemd setups (verified
on Ubuntu 26.04 via a systemd-nspawn-less apt install) the package installs
with **"NOT starting on installation"** and no password is printed at all.
Start the service first, then reset the password explicitly:

```bash
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s
```

(`-b -s` runs it non-interactively and prints just the password — do this
after `systemctl enable --now elasticsearch` below if the install didn't
print one, or any time you miss it.)

On a small box, pin the heap so Elasticsearch doesn't grab half your RAM:

```bash
echo -e "-Xms1g\n-Xmx1g" | sudo tee /etc/elasticsearch/jvm.options.d/heap.options
```

Start it and check it's alive:

```bash
sudo systemctl enable --now elasticsearch

export ELASTIC_PASSWORD='paste-the-password-here'
sudo curl --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:$ELASTIC_PASSWORD https://localhost:9200
```

You should get back a JSON blob with a cluster name and version. That `--cacert`
flag matters: security is on, so Elasticsearch is serving HTTPS with a
self-signed certificate, and every request from here on needs it plus
`-u elastic:$ELASTIC_PASSWORD`. Note the `sudo` on the `curl` itself, not just
on installing things: `/etc/elasticsearch/certs/http_ca.crt` is `root:elasticsearch`,
mode `640`, so a plain user account can't open it — every `curl --cacert
.../http_ca.crt` command in this guide needs `sudo` in front of it, not just
`export ELASTIC_PASSWORD`.

## 2. Kibana

```bash
sudo apt install -y kibana
```

Kibana needs to enroll with Elasticsearch before it will start. Generate a
token, then run the interactive setup:

```bash
sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
sudo /usr/share/kibana/bin/kibana-setup --enrollment-token <paste-token-here>
```

The apt package's Kibana only binds to `127.0.0.1` by default
(`server.host` in `/etc/kibana/kibana.yml`) — fine on the same machine, but
unreachable from your browser if Kibana is on a remote box like an EC2
instance. If you're not opening it from `localhost`, add before starting:

```bash
echo 'server.host: "0.0.0.0"' | sudo tee -a /etc/kibana/kibana.yml
```

Start it, then open `http://<host>:5601` in a browser (`https://localhost:5601`
if you're on the box itself and didn't change `server.host`):

```bash
sudo systemctl enable --now kibana
```

You should land straight on a login page. The "first load asks for a
verification code" flow only applies to a Kibana that's never been paired
with a cluster and configures itself interactively through the browser —
since you already ran `kibana-setup --enrollment-token` above, that pairing
is done, and `kibana-verification-code` will just say "Couldn't find
verification code... you can safely ignore this message." Log in as
`elastic` with the password from step 1.

## 3. The movie catalogue

Get the data. This repo's `data-loader/movies/movies.json.gz` is the same
6,959-movie set used everywhere else in this project:

```bash
git clone https://github.com/LondheShubham153/Elastiflix.git
cd Elastiflix
git checkout elk-one-shot
```

Elasticsearch's `_bulk` API and Logstash's `file` input both want one JSON
document per line, not one big array, so convert it:

```bash
mkdir -p /tmp/elastiflix-data
python3 - <<'PY'
import gzip, json
with gzip.open("data-loader/movies/movies.json.gz", "rt", encoding="utf-8") as fh:
    movies = json.load(fh)
with open("/tmp/elastiflix-data/movies.ndjson", "w", encoding="utf-8") as out:
    for m in movies:
        out.write(json.dumps(m, ensure_ascii=False) + "\n")
print(f"{len(movies)} movies ready")
PY
```

### Create the index with a real mapping first

Elasticsearch will happily create an index the first time you send it a
document, guessing field types as it goes. Don't let it. Guessed mappings turn
dates into strings and make aggregations fail later, and you can't fix a
mapping without reindexing. Install the mapping this repo already ships,
`elk/logstash/templates/movies-template.json`, as an index template:

```bash
sudo curl --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:$ELASTIC_PASSWORD \
  -X PUT "https://localhost:9200/_index_template/elastiflix-movies" \
  -H 'Content-Type: application/json' \
  -d @elk/logstash/templates/movies-template.json
```

Any index named `elastiflix-movies` created from here on uses this mapping
automatically.

## 4. Logstash

Install it:

```bash
sudo apt install -y logstash
```

Logstash needs credentials to write to a secured cluster. Store the password in
its keystore rather than a plaintext file. A fresh apt install has no keystore
yet, so create one first — it'll warn about running without a keystore
password, which is fine for a learning box:

```bash
echo "y" | sudo /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash create
echo "$ELASTIC_PASSWORD" | sudo /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash add ELASTIC_PASSWORD
```

Logstash 9.5.4's `logstash-keystore add` **lowercases whatever key name you
give it** — `add ELASTIC_PASSWORD` actually stores it as `elastic_password`
(confirmed with `logstash-keystore list`, and reproduced with an unrelated
test key). The pipeline output blocks below reference it as
`${elastic_password}`, lowercase, to match what's actually in the keystore —
not `${ELASTIC_PASSWORD}`.

Copy this repo's index templates and pipeline files into place:

```bash
sudo mkdir -p /etc/logstash/templates /etc/logstash/pipeline
sudo cp elk/logstash/templates/*.json /etc/logstash/templates/
sudo cp elk/logstash/pipeline/*.conf /etc/logstash/pipeline/
sudo cp elk/logstash/config/logstash.yml /etc/logstash/logstash.yml
```

That last copy overwrites the apt package's own `logstash.yml`, which
normally sets `path.data: /var/lib/logstash` (owned by the `logstash`
service user). The Docker version of this file doesn't set `path.data` at
all — Docker doesn't need it, the container has its own filesystem — so
after this copy Logstash falls back to `LS_HOME/data`
(`/usr/share/logstash/data`), which is `root`-owned and not writable by the
`logstash` user. It fails to start with `Path "/usr/share/logstash/data"
must be a writable directory`. Add the setting back:

```bash
echo "path.data: /var/lib/logstash" | sudo tee -a /etc/logstash/logstash.yml
```

Two more things need to change from the Docker versions, because the host and
security are different here. In both `/etc/logstash/pipeline/movies.conf` and
`/etc/logstash/pipeline/logs.conf`, the `output { elasticsearch { ... } }`
block needs HTTPS and credentials instead of `${ES_HOST}`:

```
output {
  elasticsearch {
    hosts       => [ "https://localhost:9200" ]
    ssl_enabled => true
    ssl_certificate_authorities => [ "/etc/elasticsearch/certs/http_ca.crt" ]
    user        => "elastic"
    password    => "${elastic_password}"   # lowercase — see the keystore note above
    ...
    template    => "/etc/logstash/templates/movies-template.json"   # was /usr/share/logstash/...
  }
}
```

That's `ssl_certificate_authorities`, not `cacert`: this repo's Docker
pipelines never needed a CA option at all (security is off), but the version
of the `logstash-output-elasticsearch` plugin bundled with 9.5.4 has also
dropped the older `cacert` setting entirely — using it is a hard
`ConfigurationError` at pipeline startup, not a deprecation warning.

One more permission to fix before starting Logstash: the `logstash` service
user isn't in the `elasticsearch` group, so it can't read
`/etc/elasticsearch/certs/http_ca.crt` (root:elasticsearch, mode 640) either,
and the pipeline will fail to connect. Fix it once:

```bash
sudo usermod -aG elasticsearch logstash
```

And in `movies.conf`, point the file input at the ndjson you generated in step 3:

```
input {
  file {
    path           => "/tmp/elastiflix-data/movies.ndjson"
    start_position => "beginning"
    sincedb_path   => "/dev/null"
    codec          => json
    mode           => "read"
  }
}
```

Now write `/etc/logstash/pipelines.yml` to run both pipelines as separate,
isolated pipelines. This matters: point Logstash's default `path.config` at a
directory instead, and it concatenates every `.conf` file in it into a single
pipeline, silently wiring your movie loader into your log receiver.

```yaml
- pipeline.id: movies
  path.config: "/etc/logstash/pipeline/movies.conf"
  pipeline.workers: 2

- pipeline.id: applogs
  path.config: "/etc/logstash/pipeline/logs.conf"
  pipeline.workers: 1
```

Start it:

```bash
sudo systemctl enable --now logstash
```

Give it a minute, then check the movies landed:

```bash
sudo curl --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:$ELASTIC_PASSWORD https://localhost:9200/elastiflix-movies/_count
```

That should read 6959. If it doesn't, `sudo journalctl -u logstash -f` shows
exactly which stage is failing.

## 5. Run the app, so there's something to search

If you skipped Node for the earlier steps, install it now (Ubuntu 24.04/26.04
ship Node 18+ directly in the default repo, no NodeSource setup needed):

```bash
sudo apt install -y nodejs npm
```

The Elastiflix backend already logs one JSON object per request to stdout
(`backend/src/logger.js`), which is exactly what a log pipeline wants.
`backend/src/*Connector.js` only takes `host` + `apiKey` — there's no
username/password option — so create a scoped API key rather than reusing
the `elastic` superuser password:

```bash
sudo curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:$ELASTIC_PASSWORD \
  -X POST "https://localhost:9200/_security/api_key" \
  -H 'Content-Type: application/json' \
  -d '{"name":"elastiflix-backend"}'
```

That returns `id`, `api_key`, and `encoded`. Use `encoded` — the connector
sends whatever you give it verbatim as `Authorization: ApiKey <value>`, and
Elasticsearch expects that to be base64(`id:api_key`), not the plaintext
`api_key:id` pair. Getting this wrong doesn't 401 cleanly: the connector
crashes with `Cannot read properties of undefined (reading 'total')`,
because it reads `response.hits.total` without checking for an error body
first.

The other half is TLS: the connector does a plain `fetch()` against
`https://localhost:9200` with no CA option, so it rejects Elasticsearch's
self-signed certificate outright (`fetch failed`) unless Node is told to
trust it:

```bash
cd backend
npm install
NODE_EXTRA_CA_CERTS=/etc/elasticsearch/certs/http_ca.crt \
  ES_HOST=https://localhost:9200 ES_API_KEY='<the encoded value>' \
  ES_INDEX=elastiflix-movies LOCAL=true \
  npm start > /tmp/elastiflix-data/backend.log 2>&1 &
```

(`sudo`-owned certs are unreadable to a plain `npm start`; either
`sudo chmod +r` the file or copy it somewhere your user owns, e.g.
`/tmp/elastiflix-data/http_ca.crt`, and point `NODE_EXTRA_CA_CERTS` there instead.)

For the frontend:

```bash
cd ../frontend
npm install --force
REACT_APP_ES_API=http://localhost:17700/api npm start
```

`--force` isn't optional here — `react-scripts@5.0.1`'s peer dependency on
`typescript@^3.2.1 || ^4` conflicts with what's actually in `package.json`,
and a plain `npm install` refuses outright with `ERESOLVE`. The Docker image
hits the same wall, which is why `frontend/Dockerfile` already runs
`npm install --force`.

Open `http://localhost:3000` and search for a few movies. Each search writes a
line to `backend.log`.

## 6. Filebeat

```bash
sudo apt install -y filebeat
```

No Docker here, so skip the `autodiscover` setup the repo's `filebeat.yml`
uses and tail the log file directly. Write `/etc/filebeat/filebeat.yml`:

```yaml
filebeat.inputs:
  - type: filestream
    id: elastiflix-backend
    paths:
      - /tmp/elastiflix-data/backend.log

output.logstash:
  hosts: ["localhost:5044"]
```

Start it:

```bash
sudo systemctl enable --now filebeat
```

Search a few more movies in the browser, then check the logs arrived:

```bash
sudo curl --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/elastiflix-logs-*/_count"
```

## 7. Metricbeat

```bash
sudo apt install -y metricbeat
```

There's no Docker to watch on a bare box, so use the `system` module instead
of the repo's `docker` module. It's the same idea: a Beat sitting on the thing
being monitored, shipping CPU, memory and disk straight to Elasticsearch since
there's no transform needed.

A plain `export ELASTIC_PASSWORD=...` won't reach Metricbeat's `${VAR}`
substitution — that only resolves from the *Beat's own* process
environment, and neither a plain `sudo metricbeat ...` nor the systemd
service inherit your shell's exports. Use Metricbeat's keystore instead,
the same idea as Logstash's in step 4 but — unlike Logstash's — it
preserves the case of the key you give it:

```bash
echo "y" | sudo metricbeat keystore create
echo "$ELASTIC_PASSWORD" | sudo metricbeat keystore add ELASTIC_PASSWORD --stdin
```

Write `/etc/metricbeat/metricbeat.yml`:

```yaml
metricbeat.modules:
  - module: system
    metricsets: ["cpu", "memory", "network", "filesystem"]
    period: 10s

  - module: elasticsearch
    metricsets: ["node", "node_stats", "index"]
    hosts: ["https://localhost:9200"]
    ssl.certificate_authorities: ["/etc/elasticsearch/certs/http_ca.crt"]
    username: "elastic"
    password: "${ELASTIC_PASSWORD}"
    period: 30s

output.elasticsearch:
  hosts: ["https://localhost:9200"]
  ssl.certificate_authorities: ["/etc/elasticsearch/certs/http_ca.crt"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"

setup.kibana:
  host: "http://localhost:5601"

setup.dashboards.enabled: true
```

Two things differ from what you'd guess by analogy with Elasticsearch:
`setup.kibana.host` is **`http`**, not `https` — the apt Kibana package
doesn't enable its own TLS by default even with a secured Elasticsearch
behind it (see the note in step 2), so there's no `ssl.certificate_authorities`
to give it either. And this config has a single `output.elasticsearch` block
with `username`/`password` properly nested under it — a stray pair of
top-level `username:`/`password:` lines outside any block (easy to
type by accident when copy-pasting the Elasticsearch block's shape) are not
valid Metricbeat settings and get silently ignored, not merged into the
output.

(Using the `elastic` superuser here is a shortcut for a learning box. A real
deployment would use the built-in `kibana_system` account or a scoped API key
instead.)

```bash
sudo systemctl enable --now metricbeat
```

`setup.dashboards.enabled: true` loads roughly 110 prebuilt Metricbeat
dashboards into Kibana on first run. That takes a few minutes and blocks
metric shipping while it happens; this is expected, not a hang.

## 8. Build the dashboard in Kibana

By now Elasticsearch holds three kinds of data: the movie catalogue, app
search logs, and system metrics. Kibana needs a data view before it can chart
any of them; a data view is just "which indices, and which field is time".

In Kibana, go to **Stack Management > Data Views > Create data view** and make
three:

| Name | Index pattern | Time field |
|---|---|---|
| Elastiflix Movies | `elastiflix-movies` | `release_date` |
| Elastiflix App Logs | `elastiflix-logs-*` | `@timestamp` |
| Elastiflix Metrics | `metricbeat-*` | `@timestamp` |

Then, to see the raw data: **Discover**, pick the Elastiflix Movies data view,
and you're looking at real documents. Switch to Elastiflix App Logs after
you've searched a few things in the app, and you'll see your own searches
land as documents in real time.

To build a dashboard: **Dashboards > Create dashboard > Create visualization**.
A couple worth building by hand, since they show what the mapping decisions
above bought you:

- A **bar chart** on the Elastiflix Movies data view: split by `genres`
  (a `keyword` field, so it aggregates), count of documents. This only works
  because the mapping set `genres` to `keyword` instead of letting it default
  to `text`.
- A **line chart** on Elastiflix App Logs: count of documents over `@timestamp`,
  filtered to `result_count: 0`. That's every zero-result search, a real
  product signal, not something dumped into a `message` string.

Save both panels to a dashboard and you've built, from raw indices to a chart
someone can act on, the same thing `./load-dashboards.sh` does automatically
in the Docker demo by importing `elk/kibana/dashboards.ndjson`.

## Stopping everything

```bash
sudo systemctl stop metricbeat filebeat logstash kibana elasticsearch
```

Data stays on disk under `/var/lib/elasticsearch` until you remove the
packages. `sudo apt purge elasticsearch kibana logstash filebeat metricbeat`
if you want it gone entirely.

## What you just did, versus `./start.sh`

Every step above is a manual version of something the Docker demo automates:

| By hand | `./start.sh` equivalent |
|---|---|
| apt install + systemctl enable, five times | `docker compose up -d`, seven containers |
| Password, enrollment token, TLS cert handling | `xpack.security.enabled=false`, deliberately, for a demo |
| Copying pipeline files and fixing paths | `docker-compose.yml` bind-mounts `elk/logstash/pipeline` directly |
| Creating three data views by clicking through Kibana | a `curl` loop in `start.sh` does it in seconds |
| Building two panels manually | `./load-dashboards.sh` imports three finished dashboards |

Same four components, same result. The Docker path is what you run when you
want the demo working in one command. This one is what you run when you want
to know why each of those commands exists.
