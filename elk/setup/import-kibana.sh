#!/usr/bin/env bash
# Restore the saved dashboard. The escape hatch -- if the live build fails,
# this puts the finished dashboard back in one command.
set -euo pipefail
cd "$(dirname "$0")/.."
KB="${KB:-http://localhost:5601}"
SRC="kibana/elastiflix-dashboard.ndjson"

[[ -f "$SRC" ]] || { echo "ERROR: $SRC not found -- run export-kibana.sh first" >&2; exit 1; }

echo "==> Importing $SRC into $KB"
curl -fs -X POST "$KB/api/saved_objects/_import?overwrite=true" \
  -H 'kbn-xsrf: true' -F file=@"$SRC" | python3 -m json.tool | head -20
echo "==> Open Kibana -> Dashboards"
