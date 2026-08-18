#!/usr/bin/env bash
# Export OUR Kibana saved objects to elk/kibana/elastiflix-dashboard.ndjson.
#
# Scoped deliberately: Metricbeat ships ~950 prebuilt saved objects, so an
# unfiltered export is useless. This grabs the three Elastiflix data views
# plus any dashboard whose title contains "Elastiflix", and follows their
# references so the visualisations come along.
#
# Run it AFTER you've built the dashboard you like, then commit the result --
# import-kibana.sh restores it if the live build goes sideways on camera.
set -euo pipefail
cd "$(dirname "$0")/.."
KB="${KB:-http://localhost:5601}"
OUT="kibana/elastiflix-dashboard.ndjson"
mkdir -p kibana

echo "==> Finding Elastiflix dashboards on $KB"
IDS=$(curl -fs "$KB/api/saved_objects/_find?type=dashboard&search=Elastiflix*&search_fields=title&per_page=100" \
      | python3 -c "import json,sys; print(' '.join(o['id'] for o in json.load(sys.stdin)['saved_objects']))")

OBJECTS='{"type":"index-pattern","id":"elastiflix-movies"},
         {"type":"index-pattern","id":"elastiflix-logs"},
         {"type":"index-pattern","id":"elastiflix-metrics"}'

if [[ -n "$IDS" ]]; then
  for id in $IDS; do OBJECTS="$OBJECTS,{\"type\":\"dashboard\",\"id\":\"$id\"}"; done
  echo "    found $(wc -w <<< "$IDS" | tr -d ' ') dashboard(s)"
else
  echo "    no Elastiflix dashboard yet -- exporting data views only"
fi

curl -fs -X POST "$KB/api/saved_objects/_export" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d "{\"objects\":[$OBJECTS],\"includeReferencesDeep\":true}" > "$OUT"

echo "==> Wrote $(wc -l < "$OUT" | tr -d ' ') objects to $OUT"
