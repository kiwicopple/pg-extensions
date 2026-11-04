#!/bin/sh
# Download the automerge-paper editing trace (if missing) and regenerate traces/*.jsonl.
# The download is untrusted data: it lives in its own directory and is only parsed as JSON.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
raw="$here/traces/raw/automerge-paper.json.gz"
if [ ! -f "$raw" ]; then
  mkdir -p "$here/traces/raw"
  curl -sSL -o "$raw" https://github.com/josephg/editing-traces/raw/master/sequential_traces/automerge-paper.json.gz
fi
node "$here/convert-trace.mjs" "$raw" "$here/traces" "$@"
