#!/usr/bin/env bash
# Remove everything, including the indexed data and the generated catalogue.
# Use this between rehearsals to prove the whole thing rebuilds from scratch.
set -euo pipefail
cd "$(dirname "$0")"
docker compose down -v --remove-orphans
rm -f elk/data/movies.ndjson
echo "Everything removed."
