# Elastic Stack in One Shot — Elasticsearch, Logstash, Beats & Kibana

This is a fork of [`elastic/Elastiflix`](https://github.com/elastic/Elastiflix), Elastic's
Netflix-style movie search demo, extended so it teaches the **whole** Elastic Stack rather than
just Elasticsearch.

Upstream Elastiflix ships a React frontend, an Express backend and a Python data loader — and
expects you to bring your own Elastic Cloud cluster. This fork adds the missing pieces so you can
run everything locally and see all four components doing real work on one application:

| Component | What it does here |
|---|---|
| **Elasticsearch** | Stores and searches 6,959 movies |
| **Logstash** | Loads the movie catalog, and parses the app's logs |
| **Beats** | Filebeat ships app logs, Metricbeat ships container metrics |
| **Kibana** | Explore the data and build the dashboard |

The nice symmetry: **Elastiflix is both the app *using* Elasticsearch and the app *monitored by*
Elasticsearch.**

---

## Quick start

Requirements: Docker Desktop with **at least 8 GB** allocated (Settings → Resources → Memory;
12 GB is comfortable), and Python 3.

```bash
git clone https://github.com/LondheShubham153/Elastiflix.git
cd Elastiflix
git checkout elk-one-shot

./elk/setup/00-prepull.sh       # pull + build everything up front
./elk/setup/01-prepare-data.sh  # movies.json.gz -> NDJSON for Logstash
./elk/setup/02-start-stack.sh   # bring the whole stack up
```

The remaining scripts are optional helpers:

| Script | What it's for |
|---|---|
| `03-generate-traffic.sh` | Fires ~36 realistic searches (including deliberate zero-result ones) so the Kibana dashboard isn't empty |
| `04-kibana-dataviews.sh` | Creates the three data views — already run by `02` |
| `05-export-kibana.sh` | Saves your dashboard to `elk/kibana/` once you've built it |
| `06-import-kibana.sh` | Restores it. The escape hatch if a live build goes wrong |
| `99-teardown.sh` | Full cleanup including volumes |

Then:

| Service | URL |
|---|---|
| Elastiflix | http://localhost:3000 |
| Kibana | http://localhost:5601 |
| Elasticsearch | http://localhost:9200 |
| Logstash monitoring API | http://localhost:9600 |

Watch the catalog land:

```bash
curl -s localhost:9200/elastiflix-movies/_count
# -> {"count":6959,...}
```

Tear it all down with `./elk/setup/99-teardown.sh`.

---

## What this fork changes

Everything new lives in `elk/`. Only four upstream files were touched, so you can diff this
branch against `upstream/main` and see exactly what was added.

### 1. Structured logging in the backend — `backend/src/logger.js`

Upstream logged `console.info("Search request:", state, queryConfig)`: a multi-line JS object
dump with no HTTP method, no status code and no latency. Nothing a log pipeline can aggregate.

This fork emits one JSON object per line:

```json
{"@timestamp":"2026-08-18T09:14:02.881Z","level":"info","service":"elastiflix-backend",
 "method":"POST","path":"/api/search","status":200,"duration_ms":42,
 "search_type":"lexical","query":"matrix","results":12,"page":1}
```

That `query` field is what powers the "top search terms" panel in Kibana. It also adds `try/catch`
to the search handlers — upstream had none, so an Elasticsearch error became an unhandled
rejection and the browser just hung.

Zero new npm dependencies.

### 2. Logstash replaces the Python loader — `elk/logstash/pipeline/movies.conf`

Same `movies.json.gz`, same target index, but declarative. The pipeline does three things a
plain bulk load doesn't:

- **Type coercion** — `id` is an integer in the source but a `keyword` in the mapping
- **Enrichment** — the UI renders a `user_score` facet, but *not one of the 6,959 source
  documents contains that field*, so upstream's facet is permanently empty. We derive it from
  `vote_average` (same 0–10 scale) and the facet works
- **Quality gates** — drops untitled records, handles empty dates

Compare it with `data-loader/index-data.py` side by side. That contrast is the argument for
Logstash.

### 3. Beats — `elk/beats/`

- `filebeat.yml` — autodiscovers the Elastiflix containers and ships their stdout to **Logstash**
  (not straight to ES), so the full `Beats → Logstash → Elasticsearch → Kibana` path is visible
- `metricbeat.yml` — Docker + Elasticsearch modules, shipping **direct to Elasticsearch**,
  because there's nothing to transform. Logstash is a choice, not a mandatory tax

Metricbeat also loads its prebuilt dashboards into Kibana automatically.

### 4. Upstream bugs fixed

| Bug | Fix |
|---|---|
| `pip-requirements.txt` pinned `elasticsearch==8.4.0`, far too old for the `inference.put` / `semantic_text` APIs the loader calls — it could not run as published | Bumped to `9.1.0`, added the undeclared `tqdm` |
| `docker-compose.yml` set `ES_INDEX=elastiflix-movies` but `index-data.py` defaulted to `movies`, so following the README gave `index_not_found` | Default changed to `elastiflix-movies` |
| `parallel_bulk(chunk_size=10)` — needlessly slow | Raised to 500 |
| Compose pointed at a placeholder Elastic Cloud URL requiring a hand-pasted API key | Points at local Elasticsearch, no credentials needed |

---

## A note on security

`xpack.security.enabled=false` in `elk/docker-compose.elk.yml`. That is deliberate: this is a
local teaching demo and it removes passwords, TLS certificates and API keys as things that can
break mid-lesson. **Never run a real cluster this way.**

## Semantic search / ELSER

Upstream Elastiflix also demos ELSER semantic search and hybrid retrieval. That's deliberately
**not** covered here — it needs an ML node and a trial licence, and the model download makes it
fragile. The `plot_elser` / `plot_e5` fields are stripped from the index template in this fork.
The `/api/semantic/search` and `/api/hybrid/search` routes still exist and will error without
those inference endpoints.

---

## Credits

Built on [`elastic/Elastiflix`](https://github.com/elastic/Elastiflix) (MIT). Movie data from
[TMDB](https://www.themoviedb.org/).
