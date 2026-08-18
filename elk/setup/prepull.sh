#!/usr/bin/env bash
# Pull every image and pre-build the app images BEFORE you hit record.
# A stalled docker pull is the most common way a live demo dies.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "==> Pulling Elastic Stack images (the slow part — do it early)"
docker compose pull

echo "==> Pre-building the Elastiflix app images"
# The frontend Dockerfile runs `npx update-browserslist-db` at build time,
# which needs network. Building now means recording never waits on it.
docker compose build

echo
echo "All images cached. You are safe to record."
