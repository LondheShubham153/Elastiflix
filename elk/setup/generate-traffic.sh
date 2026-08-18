#!/usr/bin/env bash
# Fire realistic searches at Elastiflix so Kibana has something to chart.
# Handy before recording the dashboard segment -- an empty dashboard is a
# boring dashboard.
set -euo pipefail

API="${API:-http://localhost:17700/api/search}"
ROUNDS="${1:-3}"

QUERIES=(
  "matrix" "batman" "star wars" "godfather" "inception" "titanic"
  "lord of the rings" "toy story" "jurassic park" "the shining"
  "pulp fiction" "avatar" "interstellar" "gladiator" "up"
  # deliberate zero-result searches -- these show up tagged in Kibana
  "zzzzz" "qwertyuiop" "asdfgh"
)

echo "==> Sending $(( ${#QUERIES[@]} * ROUNDS )) searches to $API"
for _ in $(seq 1 "$ROUNDS"); do
  for q in "${QUERIES[@]}"; do
    curl -s -o /dev/null -X POST "$API" \
      -H 'Content-Type: application/json' \
      -d "{\"state\":{\"searchTerm\":\"$q\",\"current\":1},
           \"queryConfig\":{\"search_fields\":{\"title\":{\"weight\":2},\"overview\":{}},
           \"result_fields\":{\"title\":{\"raw\":{}}},\"resultsPerPage\":10}}"
    sleep 0.2
  done
done
echo "==> Done. Give Filebeat ~10s, then check Kibana."
