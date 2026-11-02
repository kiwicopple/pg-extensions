#!/usr/bin/env bash
# Vendor the official JSON Schema Test Suite's Draft 2020-12 tests. Run once;
# the output is committed. Then run generate.py to rebuild the TAP specs.
#
#   test/json_schema/vendor.sh
#
# Writes (relative to this directory):
#   upstream/tests/draft2020-12/   verbatim copy (required, optional, optional/format)
#   upstream/LICENSE               MIT, from the same commit
#   upstream/SOURCE                repository, commit, date
#
# Needs git. The clone goes into a new empty temp directory; nothing from it
# is executed.
set -euo pipefail

REPO=https://github.com/json-schema-org/JSON-Schema-Test-Suite
SHA=3f05891cac5d51ffa068d7076d1372130e00c829        # main, 2026-10-31

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/src"
git -C "$WORK/src" init -q
git -C "$WORK/src" fetch -q --depth 1 "$REPO" "$SHA"
git -C "$WORK/src" checkout -q FETCH_HEAD
got=$(git -C "$WORK/src" rev-parse HEAD)
[ "$got" = "$SHA" ] || { echo "error: fetched $got, expected $SHA" >&2; exit 1; }

rm -rf "$HERE/upstream"
mkdir -p "$HERE/upstream/tests"
cp -R "$WORK/src/tests/draft2020-12" "$HERE/upstream/tests/draft2020-12"
cp "$WORK/src/LICENSE" "$HERE/upstream/LICENSE"
cat > "$HERE/upstream/SOURCE" <<SRC
Repository: $REPO
Commit:     $SHA
Directory:  tests/draft2020-12
License:    MIT (upstream/LICENSE). Copyright (c) 2012 Julian Berman.
Vendored:   $(date +%Y-%m-%d) by test/json_schema/vendor.sh

The files are verbatim. generate.py turns them into test/spec/4[0-2]_json_schema_suite*.sql;
expectations are never modified. Cases that are not run are listed in skip.tsv with the reason.
SRC
echo "vendored $(find "$HERE/upstream/tests" -name '*.json' | wc -l | tr -d ' ') files at $SHA"
