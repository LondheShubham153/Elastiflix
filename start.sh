#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Elastic Stack in One Shot — start everything.
#
#      ./start.sh
#
#  That's it. There's no step 2.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

ES="http://localhost:9200"
KB="http://localhost:5601"

# --- 1. The movie catalogue -------------------------------------------------
# Elastiflix ships movies.json.gz: one big JSON array. Logstash's file input
# wants one document per line, so convert it. Skipped if already done.
#
# Written to a temp file and moved into place, so a Ctrl-C halfway through
# never leaves a truncated catalogue that the next run would happily reuse.
if [[ ! -f elk/data/movies.ndjson ]]; then
  echo "==> Preparing the movie catalogue"
  mkdir -p elk/data
  python3 - <<'PY'
import gzip, json, os
with gzip.open("data-loader/movies/movies.json.gz", "rt", encoding="utf-8") as fh:
    movies = json.load(fh)
tmp = "elk/data/.movies.ndjson.tmp"
with open(tmp, "w", encoding="utf-8") as out:
    for m in movies:
        out.write(json.dumps(m, ensure_ascii=False) + "\n")
os.replace(tmp, "elk/data/movies.ndjson")
print(f"    {len(movies)} movies ready")
PY
fi

EXPECTED=$(wc -l < elk/data/movies.ndjson | tr -d ' ')

# --- 2. The stack -----------------------------------------------------------
echo "==> Starting the Elastic Stack + Elastiflix"
docker compose up -d

# --- 3. Wait for it ---------------------------------------------------------
# Every wait is bounded. A demo that hangs forever with no message is worse
# than one that fails and tells you which log to read.
wait_for() {
  local what="$1" tries="$2" hint="$3"; shift 3
  printf "==> Waiting for %s" "$what"
  for ((i = 0; i < tries; i++)); do
    if "$@" >/dev/null 2>&1; then echo " ready"; return 0; fi
    printf '.'; sleep 2
  done
  echo
  echo "ERROR: $what did not come up in $((tries * 2))s." >&2
  echo "       Look at: $hint" >&2
  exit 1
}

es_up()     { curl -fs "$ES/_cluster/health"; }
kibana_up() { curl -fs "$KB/api/status" | grep -q '"level":"available"'; }
catalogue_loaded() {
  local n
  n=$(curl -fs "$ES/elastiflix-movies/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  [[ "$n" == "$EXPECTED" ]]
}

wait_for "Elasticsearch" 60  "docker compose logs elasticsearch" es_up
wait_for "Kibana"        120 "docker compose logs kibana"        kibana_up
wait_for "the catalogue" 120 "docker compose logs logstash"      catalogue_loaded
echo "    $EXPECTED movies indexed"

# --- 4. Kibana data views ---------------------------------------------------
# A data view is just "which indices am I looking at, and which field is time?"
# Kibana can't show you anything until one exists, so create them here rather
# than making it a step you have to remember on camera.
#
# allowNoIndex matters: metricbeat-* does not exist yet on a first start
# (Metricbeat spends a few minutes loading its dashboards before it publishes),
# and without it Kibana rejects the data view outright.
data_view() {
  local id="$1" title="$2" timefield="$3" name="$4"
  curl -s -X DELETE "$KB/api/data_views/data_view/$id" -H 'kbn-xsrf: true' >/dev/null 2>&1 || true
  curl -fs -X POST "$KB/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"data_view\":{\"id\":\"$id\",\"title\":\"$title\",\"timeFieldName\":\"$timefield\",\"name\":\"$name\",\"allowNoIndex\":true}}" \
    >/dev/null
  echo "    $name  ->  $title"
}

echo "==> Creating Kibana data views"
# release_date as the time field means Discover can plot the catalogue by
# release year -- a nice way to show what a "time field" actually does.
data_view "elastiflix-movies"  "elastiflix-movies" "release_date" "Elastiflix Movies"
data_view "elastiflix-logs"    "elastiflix-logs-*" "@timestamp"   "Elastiflix App Logs"
data_view "elastiflix-metrics" "metricbeat-*"      "@timestamp"   "Elastiflix Metrics"

# --- 5. The prebuilt dashboards --------------------------------------------
# Three ready-made dashboards so there is something to show immediately. You
# still build one live on camera -- these are the safety net, and the "here is
# where we are going" shot before you start.
echo "==> Loading the prebuilt dashboards"
./load-dashboards.sh | grep -v '^==>' || true

cat <<EOF

  ────────────────────────────────────────────────
   Elastiflix       http://localhost:3000
   Kibana           http://localhost:5601
   Elasticsearch    http://localhost:9200
  ────────────────────────────────────────────────

   No login — security is disabled for this demo.

   Search a few movies in Elastiflix, then look at
   Kibana → Discover to watch your own searches
   arrive as documents.

   Three dashboards are already loaded:
   Kibana → Dashboards → "Elastiflix — ..."

   Need traffic to chart?   ./generate-traffic.sh
   Reload the dashboards?   ./load-dashboards.sh
   Stop it with             ./stop.sh
EOF
