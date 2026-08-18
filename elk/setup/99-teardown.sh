#!/usr/bin/env bash
# Full cleanup, including volumes. Use between rehearsal runs to prove the
# whole thing really is reproducible from scratch.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f ../docker-compose.yml down -v --remove-orphans || true
docker compose -f docker-compose.elk.yml down -v --remove-orphans || true
rm -f data/movies.ndjson
echo "Everything torn down."
