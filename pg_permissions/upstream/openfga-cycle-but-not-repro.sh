#!/usr/bin/env bash
# Reproduction for the OpenFGA v1.22.1 report in openfga-cycle-but-not-inconsistency.md.
#
# Starts a throwaway openfga/openfga container (memory datastore), creates a
# store, writes the model and tuples from the report, runs Check, ListObjects
# and ListUsers, and prints actual against expected. The container is removed on
# exit. Needs docker, curl and jq.
#
# usage: ./openfga-cycle-but-not-repro.sh [port]     (default port 18080)
# exit status: 0 if every answer matches "expected", 1 if any differs
set -euo pipefail

PORT=${1:-18080}
IMAGE='openfga/openfga:v1.22.1@sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671'
NAME="openfga-cycle-repro-$$"
B="http://localhost:$PORT"

for tool in docker curl jq; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$NAME" -p "$PORT:8080" "$IMAGE" run --datastore-engine memory >/dev/null

ready=0
for _ in $(seq 100); do
  if curl -sf "$B/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.3
done
[ "$ready" = 1 ] || { echo "server did not become healthy on port $PORT" >&2; docker logs "$NAME" >&2 || true; exit 1; }

STORE=$(curl -sf -XPOST "$B/stores" -d '{"name":"cycle-but-not"}' | jq -r .id)

# type user
# type document
#   relations
#     define blocked: [user, document#blocked]
#     define viewer: [user] but not blocked
MODEL=$(curl -sf -XPOST "$B/stores/$STORE/authorization-models" -d '{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}' | jq -r .authorization_model_id)

curl -sf -XPOST "$B/stores/$STORE/write" -d '{"authorization_model_id":"'"$MODEL"'","writes":{"tuple_keys":[
  {"user":"user:jon","relation":"viewer","object":"document:1"},
  {"user":"user:jon","relation":"viewer","object":"document:3"},
  {"user":"document:2#blocked","relation":"blocked","object":"document:1"},
  {"user":"document:1#blocked","relation":"blocked","object":"document:2"}]}}' >/dev/null

check() { # relation object
  curl -sf -XPOST "$B/stores/$STORE/check" \
    -d '{"authorization_model_id":"'"$MODEL"'","tuple_key":{"user":"user:jon","relation":"'"$1"'","object":"'"$2"'"}}' |
    jq -r .allowed
}
list_objects() {
  curl -sf -XPOST "$B/stores/$STORE/list-objects" \
    -d '{"authorization_model_id":"'"$MODEL"'","user":"user:jon","relation":"viewer","type":"document"}' |
    jq -c '[.objects[]?] | sort'
}
list_users() {
  curl -sf -XPOST "$B/stores/$STORE/list-users" \
    -d '{"authorization_model_id":"'"$MODEL"'","object":{"type":"document","id":"1"},"relation":"viewer","user_filters":[{"type":"user"}]}' |
    jq -c '[.users[]? | .object.type + ":" + .object.id] | sort'
}

fail=0
row() { # label actual expected
  local mark=ok
  if [ "$2" != "$3" ]; then mark=DIFFERS; fail=1; fi
  printf '%-52s actual=%-28s expected=%-20s %s\n' "$1" "$2" "$3" "$mark"
}

echo "store=$STORE model=$MODEL"
row 'Check(user:jon, blocked, document:1)'               "$(check blocked document:1)" false
row 'Check(user:jon, viewer, document:1)'                "$(check viewer document:1)" false
row 'Check(user:jon, viewer, document:3)'                "$(check viewer document:3)" true
row 'ListObjects(user:jon, document, viewer)'            "$(list_objects)" '["document:3"]'
row 'ListUsers(document:1#viewer, filter user)'          "$(list_users)" '[]'

if [ "$fail" = 1 ]; then
  echo "At least one answer differs from the expected one."
  exit 1
fi
echo "All answers match the expected ones."
