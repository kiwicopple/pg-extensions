#!/usr/bin/env bash
# Vendor openfga/language's DSL semantic validation cases
# (tests/data/dsl-semantic-validation-cases.yaml) as JSON, with every case's DSL
# model converted to a JSON AuthorizationModel by the official transformer (the
# fga CLI, run in its Docker image), and the answer OpenFGA's own server gives
# when that JSON is written to it. Run once; the output is committed. Then run
# generate.py to rebuild the TAP specs.
#
#   test/fga_lang/vendor.sh
#
# Writes (relative to this directory):
#   upstream/dsl-semantic-validation-cases.yaml   verbatim copy
#   upstream/LICENSE                              Apache-2.0, from the same commit
#   upstream/SOURCE                               repository, commit, images, date
#   cases.json                                    one case per line: the upstream
#       fields verbatim (name, dsl, expected_errors, skip), plus
#       model_json   the transformer's JSON, or null if it refused the DSL
#       transform    {"exit": n, "stderr": "..."} when the transformer failed
#       server       {"http": status, "code": "...", "message": "..."}: what
#                    OpenFGA's server answered to WriteAuthorizationModel with
#                    model_json (code "" when it accepted the model)
#
# Why this commit: the language library version that openfga v1.22.1 (the
# server the rest of the suite follows) and openfga/cli v0.8.2 (the pinned
# transformer) both require in go.mod: github.com/openfga/language/pkg/go
# v0.3.2, tag pkg/go/v0.3.2.
#
# Needs git, docker, jq, curl and ruby (Psych, for YAML -> JSON; safe_load only).
# The clone is untrusted data: it goes into a new empty temp directory and
# nothing from it is executed. The fga CLI sees each model on stdin, without
# network access. The server runs in its own container (memory datastore) on a
# free loopback port and is removed on exit.
set -euo pipefail

REPO=https://github.com/openfga/language
SHA=f558baace40cebd4548ab50b6d50ce65a940babb        # tag pkg/go/v0.3.2, 2026-10-01
CLI_IMAGE=openfga/cli:v0.8.2@sha256:31a565d14d1c5ca8170d3a2225eb66517d9f490539967bcb3421613c5e2538a4
SERVER_IMAGE=openfga/openfga:v1.22.1@sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671
CASES=tests/data/dsl-semantic-validation-cases.yaml

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
SERVER=pg_permissions_fga_lang_$$
cleanup() { docker rm -f "$SERVER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir "$WORK/src"
git -C "$WORK/src" init -q
git -C "$WORK/src" fetch -q --depth 1 "$REPO" "$SHA"
git -C "$WORK/src" checkout -q FETCH_HEAD
got=$(git -C "$WORK/src" rev-parse HEAD)
[ "$got" = "$SHA" ] || { echo "error: fetched $got, expected $SHA" >&2; exit 1; }

mkdir -p "$HERE/upstream"
cp "$WORK/src/$CASES" "$HERE/upstream/dsl-semantic-validation-cases.yaml"
cp "$WORK/src/LICENSE" "$HERE/upstream/LICENSE"

ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' \
    "$HERE/upstream/dsl-semantic-validation-cases.yaml" > "$WORK/raw.json"

docker pull -q "$CLI_IMAGE" >/dev/null
docker pull -q "$SERVER_IMAGE" >/dev/null

# OpenFGA's server, memory datastore, on a free loopback port.
docker run -d --name "$SERVER" -p 127.0.0.1::8080 "$SERVER_IMAGE" run >/dev/null
PORT=$(docker port "$SERVER" 8080/tcp | head -1 | sed 's/.*://')
URL=http://127.0.0.1:$PORT
for _ in $(seq 1 50); do
    curl -sf "$URL/healthz" >/dev/null 2>&1 && break
    sleep 0.2
done
STORE=$(curl -sf -X POST "$URL/stores" -H 'content-type: application/json' -d '{"name":"fga_lang"}' | jq -r .id)
[ -n "$STORE" ] && [ "$STORE" != null ] || { echo "error: could not create a store on $URL" >&2; exit 1; }

n=$(jq 'length' "$WORK/raw.json")
: > "$WORK/cases.jsonl"
for ((i = 0; i < n; i++)); do
    jq -r ".[$i].dsl" "$WORK/raw.json" > "$WORK/model.fga"
    if docker run --rm -i --network none "$CLI_IMAGE" \
           model transform --input-format fga --output-format json --file /dev/stdin \
           < "$WORK/model.fga" > "$WORK/model.json" 2> "$WORK/transform.err" \
       && jq -e 'type == "object"' "$WORK/model.json" >/dev/null 2>&1; then
        status=$(curl -s -o "$WORK/server.json" -w '%{http_code}' -X POST \
                      "$URL/stores/$STORE/authorization-models" \
                      -H 'content-type: application/json' --data-binary @"$WORK/model.json")
        server=$(jq -c --arg http "$status" \
                    '{http: ($http | tonumber), code: (.code // ""), message: (.message // "")}' "$WORK/server.json")
        jq -c --slurpfile m "$WORK/model.json" --argjson server "$server" \
            ".[$i] + {model_json: \$m[0], server: \$server}" "$WORK/raw.json" >> "$WORK/cases.jsonl"
    else
        jq -c --arg err "$(cat "$WORK/transform.err")" \
            ".[$i] + {model_json: null, transform: {exit: 1, stderr: \$err}}" "$WORK/raw.json" >> "$WORK/cases.jsonl"
    fi
    printf '\r%d/%d' $((i + 1)) "$n" >&2
done
echo >&2
mv "$WORK/cases.jsonl" "$HERE/cases.json"

cat > "$HERE/upstream/SOURCE" <<SRC
Repository: $REPO
Commit:     $SHA (tag pkg/go/v0.3.2: the language version openfga v1.22.1
            and openfga/cli v0.8.2 both require)
File:       $CASES
License:    Apache-2.0 (upstream/LICENSE). Copyright OpenFGA authors.
Models:     converted from DSL to JSON with $CLI_IMAGE
            (fga model transform --input-format fga --output-format json)
Server:     each JSON model written to $SERVER_IMAGE
            (POST /stores/{id}/authorization-models, memory datastore)
Vendored:   $(date -u +%Y-%m-%d) by test/fga_lang/vendor.sh

cases.json is derived from dsl-semantic-validation-cases.yaml: one case per
line, the same fields, plus model_json, transform (when the transformer
refused) and server (the server's answer). Expectations are not modified.
SRC
echo "vendored $n cases from $REPO@$SHA"
