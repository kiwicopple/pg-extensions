#!/usr/bin/env bash
# Reproduction for the OpenFGA v1.22.1 report in openfga-cycle-but-not-inconsistency.md.
#
# Starts a throwaway openfga/openfga container (memory datastore) and runs four
# scenarios, each in a fresh store:
#   1. original model, cycle tuples
#   2. control model (original plus an unused team#member -> group#member -> user
#      path in `blocked`), identical tuples
#   3. original model, cycle broken (one of the two blocked userset tuples removed)
#   4. original model, cycle kept, user:jon explicitly blocked on document:2
# For each it prints Check(blocked), Check(viewer), ListObjects(viewer) and
# ListUsers(viewer) for user:jon / document:1, then whether Check, ListObjects
# and ListUsers agree on "user:jon is a viewer of document:1".
#
# The intended true/false outcome for scenarios 1 and 2 is left open in the
# report; this script only tests that the three APIs agree. After all scenarios
# it also prints whether adding the unused path (scenario 2 vs 1) changed Check
# but not ListObjects.
#
# Needs docker, curl and jq. The container is removed on exit.
#
# usage: ./openfga-cycle-but-not-repro.sh [port]     (default port 18080)
#        CONSISTENCY=HIGHER_CONSISTENCY ./openfga-cycle-but-not-repro.sh
#
# exit status:
#   0  Check, ListObjects and ListUsers agree in every scenario (not reproduced)
#   1  at least one scenario has a disagreement (the inconsistency is reproduced)
#   2  missing tool, or the server / an API call failed
set -euo pipefail

PORT=${1:-18080}
CONSISTENCY=${CONSISTENCY:-MINIMIZE_LATENCY}
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
[ "$ready" = 1 ] || { echo "server did not become healthy on port $PORT" >&2; docker logs "$NAME" >&2 || true; exit 2; }

# Original model:
#   type user
#   type document
#     relations
#       define blocked: [user, document#blocked]
#       define viewer: [user] but not blocked
ORIGINAL_MODEL='{
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
  ]}'

# Control model: same, plus an unused path to user in `blocked`:
#   type user
#   type group
#     relations
#       define member: [user]
#   type team
#     relations
#       define member: [group#member]
#   type document
#     relations
#       define blocked: [user, document#blocked, team#member]
#       define viewer: [user] but not blocked
CONTROL_MODEL='{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group",
     "relations": {"member": {"this": {}}},
     "metadata": {"relations": {
       "member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "team",
     "relations": {"member": {"this": {}}},
     "metadata": {"relations": {
       "member": {"directly_related_user_types": [{"type": "group", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}, {"type": "team", "relation": "member"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}'

JON_V1='{"user":"user:jon","relation":"viewer","object":"document:1"}'
JON_V3='{"user":"user:jon","relation":"viewer","object":"document:3"}'
CYCLE_A='{"user":"document:2#blocked","relation":"blocked","object":"document:1"}'
CYCLE_B='{"user":"document:1#blocked","relation":"blocked","object":"document:2"}'
JON_BLOCKED_D2='{"user":"user:jon","relation":"blocked","object":"document:2"}'

STORE_ID=
MODEL_ID=

api() { # path body
  curl -sf -XPOST "$B$1" -d "$2" || { echo "API call failed: $1" >&2; exit 2; }
}
check() { # relation object -> true|false
  api "/stores/$STORE_ID/check" "$(jq -n --arg m "$MODEL_ID" --arg c "$CONSISTENCY" --arg r "$1" --arg o "$2" \
    '{authorization_model_id:$m, consistency:$c, tuple_key:{user:"user:jon", relation:$r, object:$o}}')" |
    jq -r '.allowed // false'
}
list_objects() { # -> compact sorted JSON array
  api "/stores/$STORE_ID/list-objects" "$(jq -n --arg m "$MODEL_ID" --arg c "$CONSISTENCY" \
    '{authorization_model_id:$m, consistency:$c, user:"user:jon", relation:"viewer", type:"document"}')" |
    jq -c '[.objects[]?] | sort'
}
list_users() { # -> compact sorted JSON array
  api "/stores/$STORE_ID/list-users" "$(jq -n --arg m "$MODEL_ID" --arg c "$CONSISTENCY" \
    '{authorization_model_id:$m, consistency:$c, object:{type:"document", id:"1"}, relation:"viewer", user_filters:[{type:"user"}]}')" |
    jq -c '[.users[]? | .object.type + ":" + .object.id] | sort'
}

fail=0
# results of the last scenario, kept for the scenario 1 vs 2 comparison
R_CHECK_BLOCKED=; R_CHECK_VIEWER=; R_LIST_OBJECTS=; R_LIST_USERS=
ORIG_CHECK=; ORIG_LO=; CTRL_CHECK=; CTRL_LO=

scenario() { # label model_json tuples_json_array
  local label=$1 model_json=$2 tuples=$3
  STORE_ID=$(api /stores '{"name":"cycle-but-not"}' | jq -r .id)
  MODEL_ID=$(api "/stores/$STORE_ID/authorization-models" "$model_json" | jq -r .authorization_model_id)
  api "/stores/$STORE_ID/write" "$(jq -n --arg m "$MODEL_ID" --argjson t "$tuples" \
    '{authorization_model_id:$m, writes:{tuple_keys:$t}}')" >/dev/null

  R_CHECK_BLOCKED=$(check blocked document:1)
  R_CHECK_VIEWER=$(check viewer document:1)
  R_LIST_OBJECTS=$(list_objects)
  R_LIST_USERS=$(list_users)

  local lo_has lu_has agree=yes
  lo_has=$(jq -r 'index("document:1") != null' <<<"$R_LIST_OBJECTS")
  lu_has=$(jq -r 'index("user:jon") != null' <<<"$R_LIST_USERS")
  if [ "$R_CHECK_VIEWER" != "$lo_has" ] || [ "$R_CHECK_VIEWER" != "$lu_has" ]; then
    agree=NO; fail=1
  fi

  echo
  echo "== $label (store=$STORE_ID model=$MODEL_ID consistency=$CONSISTENCY)"
  printf '  %-46s %s\n' 'Check(user:jon, blocked, document:1)'      "$R_CHECK_BLOCKED"
  printf '  %-46s %s\n' 'Check(user:jon, viewer, document:1)'       "$R_CHECK_VIEWER"
  printf '  %-46s %s\n' 'ListObjects(user:jon, document, viewer)'   "$R_LIST_OBJECTS"
  printf '  %-46s %s\n' 'ListUsers(document:1, viewer, filter user)' "$R_LIST_USERS"
  printf '  %-46s %s\n' 'Check/ListObjects/ListUsers agree on viewer?' "$agree"
}

tuples() { printf '%s\n' "$@" | jq -s .; }

scenario '1. original model, cycle'           "$ORIGINAL_MODEL" "$(tuples "$JON_V1" "$JON_V3" "$CYCLE_A" "$CYCLE_B")"
ORIG_CHECK=$R_CHECK_VIEWER; ORIG_LO=$(jq -r 'index("document:1") != null' <<<"$R_LIST_OBJECTS")

scenario '2. control model (unused team path), same tuples' "$CONTROL_MODEL" "$(tuples "$JON_V1" "$JON_V3" "$CYCLE_A" "$CYCLE_B")"
CTRL_CHECK=$R_CHECK_VIEWER; CTRL_LO=$(jq -r 'index("document:1") != null' <<<"$R_LIST_OBJECTS")

scenario '3. original model, cycle broken (one blocked tuple removed)' "$ORIGINAL_MODEL" "$(tuples "$JON_V1" "$JON_V3" "$CYCLE_A")"
scenario '4. original model, cycle kept, user:jon blocked on document:2' "$ORIGINAL_MODEL" "$(tuples "$JON_V1" "$JON_V3" "$CYCLE_A" "$CYCLE_B" "$JON_BLOCKED_D2")"

echo
echo "== adding the unused team#member path (scenario 2 vs 1)"
printf '  Check(viewer, document:1):             original=%s control=%s\n' "$ORIG_CHECK" "$CTRL_CHECK"
printf '  ListObjects includes document:1:       original=%s control=%s\n' "$ORIG_LO" "$CTRL_LO"
if [ "$ORIG_CHECK" != "$CTRL_CHECK" ] && [ "$ORIG_LO" = "$CTRL_LO" ]; then
  echo "  Check changed but ListObjects did not."
fi

echo
if [ "$fail" = 1 ]; then
  echo "Inconsistency reproduced: Check, ListObjects and ListUsers disagree in at least one scenario."
  exit 1
fi
echo "No inconsistency: Check, ListObjects and ListUsers agree in every scenario."
