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
if [[ ! -f elk/data/movies.ndjson ]]; then
  echo "==> Preparing the movie catalogue"
  mkdir -p elk/data
  python3 - <<'PY'
import gzip, json
with gzip.open("data-loader/movies/movies.json.gz", "rt", encoding="utf-8") as fh:
    movies = json.load(fh)
with open("elk/data/movies.ndjson", "w", encoding="utf-8") as out:
    for m in movies:
        out.write(json.dumps(m, ensure_ascii=False) + "\n")
print(f"    {len(movies)} movies ready")
PY
fi

# --- 2. The stack -----------------------------------------------------------
echo "==> Starting the Elastic Stack + Elastiflix"
docker compose up -d

# --- 3. Wait for it ---------------------------------------------------------
printf "==> Waiting for Elasticsearch"
until curl -fs "$ES/_cluster/health" >/dev/null 2>&1; do printf '.'; sleep 2; done
echo " ready"

printf "==> Waiting for Kibana"
until curl -fs "$KB/api/status" 2>/dev/null | grep -q '"level":"available"'; do printf '.'; sleep 3; done
echo " ready"

printf "==> Loading the catalogue"
until [[ "$(curl -s "$ES/elastiflix-movies/_count" 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')" == "6959" ]]; do
  printf '.'; sleep 3
done
echo " 6959 movies indexed"

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

   Stop it with   ./stop.sh
EOF
