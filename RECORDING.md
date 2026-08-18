# Recording Runbook — Elastic Stack in One Shot

Everything below is verified against this repo's running stack. Field names are
real; if a panel here says `search_query`, that is the field that exists.

---

## Before you hit record

```bash
docker compose pull && docker compose build   # cache images — a stalled pull kills a take
./uninstall.sh                                # prove it builds from nothing
```

Raise Docker Desktop's memory to at least 12 GB (Settings → Resources). It ships
at 7.75 GB here and Elasticsearch + Kibana + Logstash + two Beats is tight.

Then, ~10 minutes before you need the metrics segment:

```bash
./start.sh
```

Metricbeat blocks metric publishing for 3–5 minutes while it loads its 112
dashboards. Start early and that wait happens off camera. Between takes:

```bash
METRICBEAT_SETUP_DASHBOARDS=false ./start.sh   # skip the reload, metrics instantly
```

---

## Windows to open

Six, and no more. Anything else is clutter on a 1080p capture.

| # | Window | What's in it | Why separate |
|---|---|---|---|
| 1 | **Terminal A — driver** | Fullscreen, large font. Where you type. | The only one you type in |
| 2 | **Terminal B — logs** | `docker compose logs -f filebeat` etc. Split pane. | Live proof, never typed into |
| 3 | **Editor** | This repo. `docker-compose.yml` open first. | The architecture *is* the file |
| 4 | **Browser tab — Elastiflix** | http://localhost:3000 | You generate the data here |
| 5 | **Browser tab — Kibana** | http://localhost:5601 | You look at it here |
| 6 | **Browser tab — Dev Tools** | http://localhost:5601/app/dev_tools#/console | Raw Elasticsearch, no UI in the way |

Keep Elastiflix and Kibana as **two tabs in the same window** so ⌘⌥→ flips
between "I did a thing" and "the thing arrived". That flip is the whole show.

Terminal B pane split, top and bottom:

```bash
# top pane
docker compose ps
# bottom pane — swap the service as each segment needs
docker compose logs -f filebeat
```

---

## The run order

### 1. Slides (~30 min)
`elk/slides/index.html` in the browser. Nothing running yet.

### 2. The architecture, before anything starts

Editor, `docker-compose.yml`, from the top. The header comment is the diagram —
read it out. Then scroll the `depends_on` graph:

```
elasticsearch (healthy)
   ├── kibana ────────── metricbeat
   ├── logstash (healthy) ─ filebeat
   ├── backend ───────── frontend
```

Say out loud: seven services, **every one of them is something you're learning**.
No init containers, no sidecars, nothing to apologise for.

### 3. Progressive start (the reveal)

Don't run `./start.sh` on camera the first time. Bring the tiers up by hand so
each one has a moment:

```bash
docker compose up -d elasticsearch kibana    # "the engine, and the window into it"
curl localhost:9200 | jq                     # a cluster, in one command
docker compose up -d logstash                # "now let's get data in"
docker compose up -d backend frontend        # "and here's the app"
docker compose up -d filebeat metricbeat     # "now let's watch it"
```

Then `./start.sh` afterwards to create the data views and confirm the count.
(It's idempotent — safe to run over a stack that's already up.)

---

## Segment: Elasticsearch, in Dev Tools

Dev Tools, not curl — the autocomplete and the formatting read far better on
video. Paste these one at a time and run with ⌘↵.

```
GET _cluster/health

GET _cat/indices?v

# 6,959 movies. This is the document — show them a real one.
GET elastiflix-movies/_search
{ "size": 1 }

# The mapping is the lesson: text vs keyword.
GET elastiflix-movies/_mapping

# Full-text search — analysed, ranked, _score.
GET elastiflix-movies/_search
{ "query": { "match": { "title": "matrix" } },
  "_source": ["title", "release_date", "vote_average"] }

# Show WHY it matched.
GET elastiflix-movies/_search
{ "query": { "match": { "title": "the matrix" } }, "explain": true, "size": 1 }

# Aggregation — genres is a keyword, so this works.
GET elastiflix-movies/_search
{ "size": 0,
  "aggs": { "by_genre": { "terms": { "field": "genres", "size": 10 } } } }
```

**The gotcha worth teaching on camera:** now try to aggregate on `title`:

```
GET elastiflix-movies/_search
{ "size": 0, "aggs": { "t": { "terms": { "field": "title" } } } }
```

It fails — *"Fielddata is disabled on [title]"*. `title` is `text`, analysed for
searching, not aggregatable. `genres` is `keyword`, aggregatable, not analysed.
That one error explains the entire text/keyword distinction better than a slide,
and it's why `search_query` is explicitly mapped as a keyword in
`elk/logstash/templates/logs-template.json`.

---

## Segment: Logstash

Editor: `elk/logstash/pipeline/movies.conf`, then `logs.conf`. Three blocks —
`input`, `filter`, `output` — and that's the whole mental model.

Points to hit in `logs.conf`:
- the `json` filter with `target => "app"` — text becomes fields
- the `rename` block — promoting what you'll chart to the top level
- `add_tag => ["zero_results"]` — **decide at ingest, not at query time**
- `manage_template` in the output — Logstash installs the mapping itself, so
  `search_query` is a keyword before the first event ever arrives

Show it running:

```bash
docker compose logs --tail 30 logstash
curl -s localhost:9600/_node/stats/pipelines | jq '.pipelines.applogs.events'
```

That `events` counter — `in`, `out`, `filtered` — climbing while you search in
Elastiflix is the best "it's alive" shot in the whole video.

---

## Segment: Beats — showing it actually working

This is the segment people fake. Don't.

**Filebeat.** Terminal B:

```bash
docker compose logs -f filebeat
```

Now switch to the Elastiflix tab and search for something. Within ~10 seconds
Filebeat's log shows the harvester activity, and the count moves:

```bash
curl -s "localhost:9200/elastiflix-logs-*/_count"
```

**The autodiscover demo — this is the money shot.** Filebeat isn't given a list
of files; it watches Docker and attaches to any container named `elastiflix-*`.
Prove it live:

```bash
docker compose restart elastiflix-backend
docker compose logs --tail 20 filebeat     # watch it drop the old input, start a new one
```

Then point at `elk/beats/filebeat.yml` and the `contains.docker.container.name:
"elastiflix"` condition. Nothing was reconfigured. That's the pitch for Beats.

Also worth saying out loud, with the file on screen: every tutorial online uses
`type: container`, which was **removed in 9.x** and silently ships nothing. This
repo uses `filestream` with a `container` parser. That single detail will save
your audience an evening.

**Metricbeat.** Different path on purpose — it goes *straight* to Elasticsearch,
no Logstash. Say why: no transformation needed, so don't pay for the hop.
Logstash is a choice, not a tax.

```bash
curl -s "localhost:9200/metricbeat-*/_count"
```

Then Kibana → Dashboards → search **"[Metricbeat Docker] Overview ECS"**. It's
already there — 112 dashboards came for free with the module. Show CPU and
memory per container, and point out that `elasticsearch` is the fat one.

---

## Segment: logs in Discover

Kibana → Discover → data view **Elastiflix App Logs**. Time range: Last 15
minutes.

Set the visible columns (left sidebar, hover a field → ⊕):
`service`, `search_query`, `result_count`, `duration_ms`, `http_status`

Now the loop that sells the whole stack:

1. Elastiflix tab → search "batman"
2. Kibana tab → refresh Discover
3. The document is there. `search_query: batman`, `result_count: 46`, `duration_ms: 2`

Do it twice. Let them see it arrive.

Filters worth showing:
- `tags: zero_results` — every search that found nothing
- `duration_ms > 100` — the slow ones
- `service: elastiflix-backend` — proves the field survives the pipeline

Search something nonsense in the app ("qwertyuiop"), then filter
`tags: zero_results` and watch it appear. Ingest-time tagging, visible.

---

## Segment: building the dashboard, live

Kibana → Dashboards → **Create dashboard** → Create visualization (Lens).
Data view **Elastiflix App Logs** for all of these.

Before you start, seed the data so panels aren't empty:

```bash
./generate-traffic.sh 3     # 54 searches, 9 of them deliberate zero-result
```

Build these five, in this order — each one teaches a different aggregation:

| # | Panel | Type | Config |
|---|---|---|---|
| 1 | **Searches over time** | Bar, vertical stacked | Horizontal: `@timestamp` (date histogram) · Vertical: **Count** |
| 2 | **Top search terms** | Table | Rows: `search_query` (Top values, size 10) · Metric: **Count** |
| 3 | **Zero-result searches** | Metric | Metric: **Count** · then add a panel filter `tags: zero_results` |
| 4 | **Search latency** | Line | Horizontal: `@timestamp` · Vertical: **Median** of `duration_ms`, then add **95th percentile** as a second layer |
| 5 | **Container CPU** | Line | *Switch data view to* **Elastiflix Metrics** · Horizontal: `@timestamp` · Vertical: **Average** of `docker.cpu.total.pct` · Break down by: `container.name` |

Panel 2 is where you cash in the earlier `text` vs `keyword` lesson — it works
*only* because `logs-template.json` mapped `search_query` as a keyword. Say so.

Panel 5 crossing to a different data view, on the same dashboard, from a beat
that never touched Logstash — that's the "one stack, many sources" payoff.

Set the time picker to **Last 30 minutes** with auto-refresh at 10s, then flip
to Elastiflix and run a few searches with the dashboard visible on a second
monitor if you have one. Live-updating panels close the video.

**Save the dashboard as "Elastiflix Overview"** the moment it looks right —
before you keep fiddling.

---

## If something breaks on camera

| Symptom | Fix |
|---|---|
| `./start.sh` times out | It names the log to read. Usually `docker compose logs logstash`. |
| Discover empty | Time range. It defaults to 15 minutes; your traffic may be older. |
| `metricbeat-*` has 0 docs | Normal for the first 3–5 min. It's loading dashboards. |
| Movie count stuck below 6959 | `./uninstall.sh && ./start.sh` — a truncated NDJSON can't happen now, but a wiped index can. |
| Everything is wedged | `./uninstall.sh && ./start.sh` is 38 seconds. Cut, rebuild, resume. |

There is no saved-dashboard escape hatch in this repo — it was removed because
the committed export contained no dashboard and restored nothing. If you want
one, build the dashboard, then export it from Kibana's Saved Objects UI and
commit it before recording.
