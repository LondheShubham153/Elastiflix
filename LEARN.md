# Elastic Stack — Notes

Minimal notes to learn from and teach with. Examples run against the stack in this repo
(`./elk/setup/02-start-stack.sh`), so everything here is copy-pasteable.

---

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

Run these in **Kibana → Dev Tools**, or with curl against `localhost:9200`.

```bash
# Is it alive?
GET /

# Index one document
POST /playground/_doc/1
{ "title": "The Matrix", "year": 1999, "genres": ["Action", "Sci-Fi"] }

# Get it back
GET /playground/_doc/1

# Search
GET /playground/_search
{ "query": { "match": { "title": "matrix" } } }
```

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

## 10. Docs

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
