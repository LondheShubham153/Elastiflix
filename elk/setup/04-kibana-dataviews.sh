#!/usr/bin/env bash
# Create the three Kibana data views. A data view is just "which indices am I
# looking at, and which field is time?" -- Kibana can't show you anything
# until one exists.
set -euo pipefail
KB="${KB:-http://localhost:5601}"

echo "==> Waiting for Kibana"
until curl -fs "$KB/api/status" | grep -q '"level":"available"'; do printf '.'; sleep 3; done
echo " ready"

create() {
  local id="$1" title="$2" timefield="$3" name="$4"
  # Delete first so re-running is safe.
  curl -s -X DELETE "$KB/api/data_views/data_view/$id" -H 'kbn-xsrf: true' >/dev/null 2>&1 || true
  local tf=""
  [[ -n "$timefield" ]] && tf="\"timeFieldName\":\"$timefield\","
  curl -fs -X POST "$KB/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"data_view\":{\"id\":\"$id\",\"title\":\"$title\",$tf\"name\":\"$name\"}}" >/dev/null
  echo "    $name  ->  $title"
}

echo "==> Creating data views"
# release_date as the time field means Discover can plot the catalogue by
# release year -- a nice way to show what a "time field" actually does.
create "elastiflix-movies"  "elastiflix-movies"   "release_date" "Elastiflix Movies"
create "elastiflix-logs"    "elastiflix-logs-*"   "@timestamp"   "Elastiflix App Logs"
create "elastiflix-metrics" "metricbeat-*"        "@timestamp"   "Elastiflix Metrics"

echo "==> Done. Kibana -> Discover and pick one."
