#!/usr/bin/env bash
# Turn Elastiflix's bundled movies.json.gz (one big JSON array) into NDJSON,
# which is what the Logstash `file` input + `json` codec expects: one document
# per line. Streaming 6,959 lines is far kinder than parsing a 40MB array.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="../data-loader/movies/movies.json.gz"
DEST="data/movies.ndjson"

mkdir -p data

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: cannot find $SRC" >&2
  exit 1
fi

echo "==> Converting movies.json.gz -> $DEST"
python3 - "$SRC" "$DEST" <<'PY'
import gzip, json, sys

src, dest = sys.argv[1], sys.argv[2]
with gzip.open(src, "rt", encoding="utf-8") as fh:
    movies = json.load(fh)

with open(dest, "w", encoding="utf-8") as out:
    for m in movies:
        out.write(json.dumps(m, ensure_ascii=False) + "\n")

print(f"    wrote {len(movies)} movies")
PY

echo "==> Done: $(wc -l < "$DEST" | tr -d ' ') lines in $DEST"
