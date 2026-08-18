# Elastic Stack — Notes

Minimal notes to learn from and teach with. Every command was run against the live stack in this
repo before being written down — the numbers are real output.

**Part 1 — the concepts** (1) why it exists · (2) the components · (3) vocabulary ·
(4) Elasticsearch by hand · (5) Logstash · (6) Beats · (7) Kibana · (8) where it's used ·
(9) misconceptions

**Part 2 — this repo** (10) every file explained · (11) every action in order ·
(12) changes to the app · (13) docs

Start the stack first: `./elk/setup/02-start-stack.sh`

---

# Part 1 — The concepts

## 1. Why it exists

A database answers **"which rows match?"**. Search has to answer **"which are most relevant?"**

```sql
SELECT * FROM movies WHERE title LIKE '%matrix%';
```

The leading `%` kills the index → full table scan. No ranking, no typo tolerance, no stemming.
Add `overview` and `cast` to the search and it gets worse.

**The fix: invert the index.**

```
normal:    doc1 → "the matrix reloaded"
inverted:  "matrix" → [doc1, doc2]
```

Like the index at the back of a textbook — you don't read the book to find a word, you look it
up. That inversion is the whole trick.

---

## 2. The components

| | Job | In this repo |
|---|---|---|
| **Elasticsearch** | Store + search. Distributed, JSON in / ranked results out, over HTTP | 6,959 movies |
| **Logstash** | Ingest pipeline. `input → filter → output`. Transforms on the way in | Loads the catalogue, parses app logs |
| **Beats** | Tiny shippers that sit *on* the monitored thing. Tail and forward, don't parse | Filebeat (logs), Metricbeat (metrics) |
| **Kibana** | The UI. Discover, Dev Tools, dashboards | One pane over all of it |

**Be honest about the naming** — it confuses everyone:

- **ELK** = Elasticsearch, Logstash, Kibana. Still what job descriptions say.
- **Elastic Stack** = ELK + Beats. Beats joined in 2015 and broke the acronym, so they renamed it.
- **Elastic Agent** = one binary replacing the many Beats, managed centrally via **Fleet**.
  Elastic's docs now say plainly: *"Beats has been replaced by Elastic Agent for most use cases."*
- **EFK** = same idea with Fluentd instead of Logstash. Common in Kubernetes.

> **Teaching note:** we use Beats here because it makes the pipeline *visible* — you can see each
> stage doing one job. Elastic Agent hides that behind one process, which is better in production
> and worse for learning. Say this out loud rather than pretending Beats is current.

---

## 3. Vocabulary

| Term | Means |
|---|---|
| **Document** | One JSON object. One movie. |
| **Index** | A collection of documents. Roughly "a table". |
| **Mapping** | The schema — field names and types. |
| **Index template** | Mapping applied automatically to indices matching a pattern. |
| **Shard** | A slice of an index. How one index spreads across machines. |
| **Replica** | A copy of a shard. Survives a dead node, serves reads in parallel. |
| **Node / Cluster** | One Elasticsearch process / a group of them. |
| **Data stream** | An append-only, time-series-shaped index behind one name. Metricbeat writes one. |
| **Query DSL** | The JSON query language. |
| **ES\|QL** | Newer pipe-based query language. `FROM x \| WHERE y \| STATS z` |

**Mapping is the one that bites you.** Get it wrong and you can't fix it later without reindexing:

- `text` → analyzed, full-text searchable, **cannot aggregate or sort**
- `keyword` → exact value, **aggregatable** — needed for facets, terms aggs, dashboards

That's why templates get applied *before* any data arrives in `02-start-stack.sh`.

---

## 4. Elasticsearch by hand

Run these in **[Kibana → Dev Tools](http://localhost:5601/app/dev_tools#/console)** — paste the
block and hit ▶ on each request.

> **Not in a browser address bar.** A browser can only send `GET`, so the `POST` below simply
> cannot run there. The `GET /path` + JSON-body syntax is Dev Tools' own shorthand — it is not a
> URL and it is not curl. The curl equivalents are further down.

```
# Is it alive?
GET /

# Index one document. This ALSO creates the index -- there is no "CREATE TABLE"
# step in Elasticsearch. Skip this and the next request 404s.
POST /playground/_doc/1
{ "title": "The Matrix", "year": 1999, "genres": ["Action", "Sci-Fi"] }

# Get it back
GET /playground/_doc/1

# Search
GET /playground/_search
{ "query": { "match": { "title": "matrix" } } }
```

Same thing with curl, if you'd rather stay in the terminal:

```bash
curl localhost:9200

curl -X POST localhost:9200/playground/_doc/1 \
  -H 'Content-Type: application/json' \
  -d '{"title":"The Matrix","year":1999,"genres":["Action","Sci-Fi"]}'

curl localhost:9200/playground/_doc/1

curl localhost:9200/playground/_search \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"title":"matrix"}}}'
```

> **`index_not_found_exception` is the expected first answer** if you run the `GET` before the
> `POST`. Worth demoing deliberately: the index does not exist until a document lands in it.

Against the real catalogue:

```bash
GET /elastiflix-movies/_count                  # 6959
GET /elastiflix-movies/_mapping                # what types did we choose?

# Full-text search, weighted across fields
GET /elastiflix-movies/_search
{ "query": { "multi_match": {
    "query": "space", "fields": ["title^3", "overview"] } } }

# Aggregation — needs a keyword field
GET /elastiflix-movies/_search
{ "size": 0,
  "aggs": { "by_genre": { "terms": { "field": "genres", "size": 10 } } } }
```

**`match` vs `term`** — the classic beginner trap. Run all three, they're a great live demo:

```bash
GET /elastiflix-movies/_search   { "query": { "term":  { "title":  "Matrix" } } }   # -> 0
GET /elastiflix-movies/_search   { "query": { "match": { "title":  "Matrix" } } }   # -> 5
GET /elastiflix-movies/_search   { "query": { "term":  { "genres": "Comedy" } } }   # -> 2128
```

- `match` analyzes your input (lowercases, stems). Use it on `text`.
- `term` does **not** analyze. Use it on `keyword`.
- `term` on a `text` field returns nothing — the stored token is `matrix`, your query says
  `Matrix`, and nothing lowercased it. Same field, same data, zero results.

---

## 5. Logstash

Three stages, always:

```ruby
input  { file { path => "/data/movies.ndjson" codec => json } }
filter { mutate { convert => { "id" => "string" } } }
output { elasticsearch { hosts => ["${ES_HOST}"] index => "elastiflix-movies" } }
```

Filters worth knowing: `grok` (parse unstructured text), `json`, `mutate` (rename/convert/remove),
`date` (parse into `@timestamp`), `drop`, `ruby` (escape hatch).

**Why not just bulk-load?** Because the data you have is never quite the data your app needs.
Real example from this repo — the UI renders a `user_score` facet, but *zero* of the 6,959 source
documents contain that field:

```ruby
ruby { code => "event.set('user_score', event.get('vote_average').to_f)" }
```

Four lines, dead facet fixed. That's the argument for Logstash.

**Gotcha:** pointing `path.config` at a *directory* concatenates every `.conf` into one pipeline.
Use `pipelines.yml` to keep them separate.

---

## 6. Beats

Deliberately dumb: tail a file, remember the position, forward the line. Parsing is Logstash's job.

- **Filebeat** — logs · **Metricbeat** — metrics · **Packetbeat** — network · **Heartbeat** — uptime

**Why not let Logstash read the files?** Logstash is a JVM that wants a gigabyte. You can't put
that on 500 servers. You can put a Beat on 500 servers.

**Ship to Logstash or straight to Elasticsearch?** Both are valid. In this repo Filebeat goes via
Logstash (there's JSON to parse), Metricbeat goes direct (nothing to transform).
Logstash is a choice, not a mandatory tax.

**Version gotcha:** most Filebeat+Docker tutorials still teach `type: container`. That input was
**removed in 9.x** — it now fails and ships nothing. Use `filestream` with a `container` parser.

---

## 7. Kibana

- **Discover** — raw documents, filtered. Where you actually debug.
- **Dev Tools** — console straight to the ES API. Keep it open.
- **Dashboards** — what management thinks the whole thing is for.
- **Data view** — "which indices am I looking at, and which field is time?" Nothing works without one.

Kibana stores no data. Every panel is a query run when you look at it.

---

## 8. Where it's used

| | |
|---|---|
| **Centralised logging** | The gateway use case. Every service's logs in one searchable place. |
| **SIEM / Security** | Threat detection over that same log data. |
| **Observability** | Logs + metrics + traces. Competes with Datadog, Splunk. |
| **Search** | What it was built for. GitHub, Wikipedia, Uber. |

---

## 9. Misconceptions worth correcting on camera

1. **"Elasticsearch is a database."** It's a search engine. No joins, no real transactions.
   Usually it sits *beside* your database, not instead of it.
2. **"ELK is only for logs."** Logs are the popular use case, not the design goal.
3. **"You need Logstash."** You don't. Beats → Elasticsearch works. Ingest pipelines exist too.
4. **"Yellow cluster health means broken."** On a single node it's *correct* — a replica can't
   be allocated to the same node as its primary, so it sits unassigned forever. Our cluster reads
   `status: yellow, unassigned_shards: 1` and is perfectly healthy. Green needs a second node.
5. **"I'll fix the mapping later."** You won't. Changing a field type needs a reindex.

---

# Part 2 — This repo

## 10. The repo, file by file

Everything we added lives in `elk/`, plus four surgical edits to upstream files. Nothing else
was touched — you can diff this branch against `upstream/main` and see the whole change.

```
elk/
├── docker-compose.elk.yml          the whole stack in one file
├── logstash/
│   ├── pipeline/movies.conf        loads the movie catalogue
│   ├── pipeline/logs.conf          receives + parses app logs
│   ├── config/pipelines.yml        keeps those two apart
│   ├── config/logstash.yml         Logstash's own settings
│   └── templates/*.json            mappings, applied before any data
├── beats/filebeat.yml              ships logs
├── beats/metricbeat.yml            ships metrics
├── setup/00..06, 99                every action, scripted
├── kibana/*.ndjson                 saved dashboard (the escape hatch)
└── slides/index.html               the theory deck
```

### `docker-compose.elk.yml` — the stack

Five services on one network. The lines that matter:

| Setting | Why |
|---|---|
| `discovery.type=single-node` | Don't look for peers. One node is the whole cluster. |
| `xpack.security.enabled=false` | **Demo only.** Removes passwords, TLS and API keys as failure modes. Never in production. |
| `ES_JAVA_OPTS=-Xms1g -Xmx1g` | Pin the heap. Unset, ES grabs a share of host RAM and starves everything else. |
| `bootstrap.memory_lock=true` | Stop the JVM heap being swapped to disk — swapping wrecks search latency. |
| `healthcheck` accepting `yellow` | On one node yellow is *correct*. Demanding green would hang forever. |
| `depends_on: condition: service_healthy` | Logstash starting before ES is up is the #1 cause of a broken first run. |

Filebeat and Metricbeat mount `/var/run/docker.sock` read-only — that's how they see other
containers. They expose no ports because they only push.

### `logstash/pipeline/movies.conf` — the ETL teaching artifact

Replaces `data-loader/index-data.py`. Three stages:

```ruby
input  { file { path => "/data/movies.ndjson" codec => json mode => "read" } }
```
`sincedb_path => "/dev/null"` means "forget what you've already read" — so re-running always
reloads. Correct for a repeatable demo, wrong for production.

```ruby
filter {
  mutate { convert => { "id" => "string" } }                    # int in source, keyword in mapping
  ruby   { code => "event.set('user_score', ...vote_average)" } # ENRICH: field the UI needs, data lacks
  date   { match => ["release_date","yyyy-MM-dd"] target => "@timestamp" }
  if ![title] { drop { } }                                      # quality gate
}
```

```ruby
output { elasticsearch { document_id => "%{id}" } }
```
Setting `document_id` makes re-runs **update** rather than duplicate. Omit it and every run
adds another 6,959 documents.

Uncomment `stdout { codec => rubydebug }` on camera to watch documents mid-flight.

### `logstash/pipeline/logs.conf` — Beats receiver

`input { beats { port => 5044 } }`, then:
- `json` filter parses our backend's JSON lines (guarded by `if [message] =~ /^\s*\{/`, so
  non-JSON noise doesn't break the pipeline)
- `mutate rename` promotes nested fields to top level so they're chartable
- tags `zero_results` and `slow_request` **at ingest**, so the dashboard doesn't recompute them

Output index is `elastiflix-logs-%{+YYYY.MM.dd}` — one index per day, the standard log pattern.

### `logstash/config/pipelines.yml`

Two pipelines, isolated. **The gotcha it exists to prevent:** point `path.config` at a directory
and Logstash concatenates every `.conf` into one pipeline — your movie loader and log receiver
get wired into each other.

### `logstash/config/logstash.yml`

Eight lines. One matters: `api.http.host`. In Logstash 8+ the old `http.host` is a **fatal**
startup error, not a warning — the container exits instantly. Most tutorials still show the old name.

### `logstash/templates/*.json` — the mappings

Applied *before* any document arrives. `movies-template.json` is upstream's `schema.json` minus
the ELSER fields (`plot_elser`, `plot_e5`, and the `copy_to` on `plot`).

`logs-template.json` exists for one reason: **`search_query` must be `keyword`.** Let dynamic
mapping guess and it becomes `text`, and then the top-search-terms panel is impossible —
"Fielddata is disabled" is the error you'll get.

### `beats/filebeat.yml`

Autodiscovers containers named `elastiflix*` (matching on the prefix keeps Elasticsearch's own
very chatty JVM logs out).

```yaml
- type: filestream
  parsers:
    - container: { stream: all, format: auto }
```

**The version trap:** almost every Filebeat+Docker tutorial still teaches `type: container`.
That input was **removed in 9.x** — it fails with "Container input is deprecated" and silently
ships nothing. `filestream` + a `container` parser is the modern form. The parser unwraps
Docker's `{"log":"...","stream":"stdout"}` envelope so `message` is the real application line.

Output goes to **Logstash**, so the full four-hop path stays visible.

### `beats/metricbeat.yml`

`docker` module (cpu, memory, network, diskio) + `elasticsearch` module, so the cluster monitors
itself. Ships **direct to Elasticsearch** — nothing to transform, so skip the hop.

`setup.dashboards.enabled: true` loads ~112 prebuilt dashboards. **This blocks metric publishing
for 3–5 minutes on a cold start** — `metricbeat-*` at zero docs early is expected, not a failure.

---

## 11. Every action, in order

| # | Command | What actually happens |
|---|---|---|
| 0 | `00-prepull.sh` | Pulls all 5 Elastic images and pre-builds the app. Do this **before** you record — a stalled pull is the most common way a live demo dies. |
| 1 | `01-prepare-data.sh` | Decompresses `movies.json.gz` (one big JSON array) into `movies.ndjson`, one document per line. Logstash's `json` codec reads line-by-line; streaming 6,959 lines beats parsing a 40 MB array. |
| 2 | `02-start-stack.sh` | ES + Kibana → wait for health → **apply both templates** → start Logstash/Beats → start the app → create data views. Order is the whole point: templates land before data. |
| 3 | `03-generate-traffic.sh` | Fires ~36 searches, including deliberate zero-result ones (`zzzzz`, `asdfgh`). An empty dashboard is a boring dashboard. |
| 4 | `04-kibana-dataviews.sh` | Creates the three data views. Already called by step 2; standalone for re-runs. |
| 5 | `05-export-kibana.sh` | Saves your dashboard to `kibana/*.ndjson`. Scoped to Elastiflix objects — an unfiltered export drags in Metricbeat's ~950 saved objects. |
| 6 | `06-import-kibana.sh` | Restores it. **The escape hatch** if a live build goes wrong on camera. |
| 99 | `99-teardown.sh` | Removes containers *and volumes*. Run it between rehearsals to prove reproducibility. |

### What to verify at each stage

```bash
curl -s localhost:9200/_cluster/health                 # yellow = fine on one node
curl -s localhost:9200/elastiflix-movies/_count        # 6959
curl -s 'localhost:9200/elastiflix-logs-*/_count'      # grows as you search
curl -s 'localhost:9200/_cat/indices?v'                # the whole picture
```

> **`_cat/indices` shows 60,596 docs for 6,959 movies.** Not a bug — it counts *nested*
> documents, and `keywords` and `belongs_to_collection` are `nested` fields. `_count` gives the
> real 6,959. A nice way to show what `nested` actually costs you.

---

## 12. Changes to the app itself

Four upstream files touched.

### `backend/src/logger.js` — new, and the reason Beats has anything to ship

Upstream logged `console.info("Search request:", state, queryConfig)` — a multi-line object dump
with no method, status or latency. A log pipeline can't aggregate that.

This emits one JSON object per line:

```json
{"@timestamp":"...","level":"info","service":"elastiflix-backend","method":"POST",
 "path":"/api/search","status":200,"duration_ms":42,"query":"matrix","results":7}
```

`query` is what powers "top search terms". No new npm dependencies — deliberately, so
`npm install` stays untouched and can't fail on camera.

### `backend/src/Backend.js` — rewired

Each route wrapped in `logged(...)`, which also adds `try/catch`. Upstream had none, so an
Elasticsearch error became an unhandled rejection and the browser just hung.

### `data-loader/` and `docker-compose.yml` — upstream bugs fixed

| Bug | Fix |
|---|---|
| `pip-requirements.txt` pinned `elasticsearch==8.4.0` — predates the `inference.put`/`semantic_text` APIs the script calls, so the loader **could not run as published** | bumped to `9.1.0`, added the undeclared `tqdm` |
| `index-data.py` defaulted to index `movies` while compose expected `elastiflix-movies` → `index_not_found` | default changed |
| `parallel_bulk(chunk_size=10)` | raised to 500 |
| compose pointed at a placeholder Elastic Cloud URL needing a hand-pasted API key | points at local ES, no credentials |

---

## 13. Docs

**Start here**
- Get started: https://www.elastic.co/docs/get-started
- The Stack explained: https://www.elastic.co/docs/get-started/the-stack
- "What is ELK" framing: https://www.elastic.co/elastic-stack

**Run it**
- Elastic Cloud free trial: https://cloud.elastic.co/registration
- Local one-liner: `curl -fsSL https://elastic.co/start-local | sh` (ES + Kibana only)
- Downloads — [Elasticsearch](https://www.elastic.co/downloads/elasticsearch) ·
  [Kibana](https://www.elastic.co/downloads/kibana) ·
  [Logstash](https://www.elastic.co/downloads/logstash)

**Go deeper**
- Full docs: https://www.elastic.co/docs
- Free training: https://www.elastic.co/training
- ELK primer webinar (good long-form pacing reference): https://www.elastic.co/webinars/introduction-elk-stack
