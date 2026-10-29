#!/usr/bin/env bash
# Vendor OpenFGA's consolidated test suite (assets/tests/consolidated_1_1_tests.yaml)
# as JSON, with every stage's DSL model converted to a JSON AuthorizationModel by
# the official transformer (the fga CLI, run in its Docker image). Run once; the
# output is committed. Then run generate.py to rebuild the TAP specs.
#
#   test/fga/vendor.sh
#
# Writes (relative to this directory):
#   upstream/consolidated_1_1_tests.yaml   verbatim copy
#   upstream/LICENSE                       Apache-2.0, from the same commit
#   upstream/SOURCE                        repository, commit, CLI image, date
#   cases.json                             one test case per line, each stage with
#                                          `model` (DSL, verbatim) and `model_json`
#
# Needs git, docker, jq and ruby (Psych, for YAML -> JSON; safe_load only).
# The clone is untrusted data: it goes into a new empty temp directory and
# nothing from it is executed. The fga CLI sees each model on stdin, without
# network access.
set -euo pipefail

REPO=https://github.com/openfga/openfga
SHA=44054f542f64e9b9589dd26a595081b3d2cfd942        # main, 2026-10-28
CLI_IMAGE=openfga/cli:v0.8.2@sha256:31a565d14d1c5ca8170d3a2225eb66517d9f490539967bcb3421613c5e2538a4
SUITE=assets/tests/consolidated_1_1_tests.yaml

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/src"
git -C "$WORK/src" init -q
git -C "$WORK/src" fetch -q --depth 1 "$REPO" "$SHA"
git -C "$WORK/src" checkout -q FETCH_HEAD
got=$(git -C "$WORK/src" rev-parse HEAD)
[ "$got" = "$SHA" ] || { echo "error: fetched $got, expected $SHA" >&2; exit 1; }

mkdir -p "$HERE/upstream"
cp "$WORK/src/$SUITE" "$HERE/upstream/consolidated_1_1_tests.yaml"
cp "$WORK/src/LICENSE" "$HERE/upstream/LICENSE"

ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))' \
    "$HERE/upstream/consolidated_1_1_tests.yaml" > "$WORK/raw.json"

docker pull -q "$CLI_IMAGE" >/dev/null

# One JSON model per stage, in test order.
n=$(jq '.tests | length' "$WORK/raw.json")
: > "$WORK/cases.jsonl"
for ((i = 0; i < n; i++)); do
    m=$(jq ".tests[$i].stages | length" "$WORK/raw.json")
    models='[]'
    for ((j = 0; j < m; j++)); do
        json=$(jq -r ".tests[$i].stages[$j].model" "$WORK/raw.json" |
               docker run --rm -i --network none "$CLI_IMAGE" \
                   model transform --input-format fga --output-format json --file /dev/stdin)
        models=$(jq -c --argjson x "$json" '. + [$x]' <<<"$models")
    done
    jq -c --argjson models "$models" \
        ".tests[$i] | .stages |= [to_entries[] | .value + {model_json: \$models[.key]}]" \
        "$WORK/raw.json" >> "$WORK/cases.jsonl"
    printf '\r%d/%d' $((i + 1)) "$n" >&2
done
echo >&2
mv "$WORK/cases.jsonl" "$HERE/cases.json"

cat > "$HERE/upstream/SOURCE" <<SRC
Repository: $REPO
Commit:     $SHA
File:       $SUITE
License:    Apache-2.0 (upstream/LICENSE). Copyright OpenFGA authors.
Models:     converted from DSL to JSON with $CLI_IMAGE
            (fga model transform --input-format fga --output-format json)
Vendored:   $(date -u +%Y-%m-%d) by test/fga/vendor.sh

cases.json is derived from consolidated_1_1_tests.yaml: one test per line, the
same fields, plus model_json on each stage. Expectations are not modified.
SRC
echo "vendored $n cases from $REPO@$SHA"
