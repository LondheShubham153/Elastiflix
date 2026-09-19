#!/usr/bin/env bash
# Stop everything, keep the data. ./start.sh brings it back as it was.
set -euo pipefail
cd "$(dirname "$0")"
docker compose down --remove-orphans
echo "Stopped. Data kept — ./start.sh to resume, ./uninstall.sh to wipe."
