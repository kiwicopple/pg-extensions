#!/usr/bin/env bash
# Ask OpenFGA v1.22.1 itself the condition questions abac_tests.yaml doesn't
# pin, for designs/d-conditions.md (section 3, "What the server says"). A
# design aid, not part of the test run: it prints one line per probe; the
# answers are recorded in the design doc, and phase 4's in-house specs should
# pin each one.
#
#   test/fga_abac/probe.sh
#
# Runs the pinned server image (memory datastore, default flags) in its own
# container on a free loopback port, removed on exit; models are converted from
# DSL with the pinned CLI image (stdin, no network). Needs docker, curl, jq.
# (JSON bodies are single-quoted arguments: macOS bash 3.2 drops braces inside
# "$(... "{...}")".)
set -euo pipefail

CLI_IMAGE=openfga/cli:v0.8.2@sha256:31a565d14d1c5ca8170d3a2225eb66517d9f490539967bcb3421613c5e2538a4
SERVER_IMAGE=openfga/openfga:v1.22.1@sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671
SERVER=pg_permissions_abac_probe_$$
WORK=$(mktemp -d)
cleanup() { docker rm -f "$SERVER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

docker run -d --name "$SERVER" -p 127.0.0.1::8080 "$SERVER_IMAGE" run >/dev/null
PORT=$(docker port "$SERVER" 8080/tcp | head -1 | sed 's/.*://')
URL=http://127.0.0.1:$PORT
for _ in $(seq 1 50); do curl -sf "$URL/healthz" >/dev/null 2>&1 && break; sleep 0.2; done

STORE=
MODEL=null
new_store() {
    STORE=$(curl -sf -X POST "$URL/stores" -H 'content-type: application/json' -d '{"name":"probe"}' | jq -r .id)
}

# label path body [jq filter for a success]: POST, adding the model id to the
# body unless it is raw (path prefixed with !), and print one line.
call() {
    local label=$1 path=$2 body=$3 filter=${4:-.} status raw=0
    case "$path" in '!'*) raw=1; path=${path#!} ;; esac
    if [ $raw = 0 ] && [ "$MODEL" != null ]; then
        body=$(jq -c --argjson m "$MODEL" '. + {authorization_model_id: $m}' <<<"$body")
    fi
    printf '%s' "$body" > "$WORK/body.json"
    status=$(curl -s -o "$WORK/out.json" -w '%{http_code}' -X POST "$URL/stores/$STORE/$path" \
                  -H 'content-type: application/json' --data-binary @"$WORK/body.json")
    if [ "$status" -ge 400 ]; then
        printf '%-62s error %s %s: %s\n' "$label" "$status" "$(jq -r .code "$WORK/out.json")" \
            "$(jq -r .message "$WORK/out.json" | head -1)"
    else
        printf '%-62s %s\n' "$label" "$(jq -c "$filter" "$WORK/out.json")"
    fi
}

# label [jq patch]: DSL on stdin, converted (then patched, for what the DSL
# can't say) and written; sets MODEL on success.
model() {
    docker run --rm -i --network none "$CLI_IMAGE" \
        model transform --input-format fga --output-format json --file /dev/stdin |
        jq -c "${2:-.}" > "$WORK/model.json"
    local m=$MODEL
    MODEL=null
    call "$1" authorization-models "$(cat "$WORK/model.json")" '.authorization_model_id'
    if jq -e .authorization_model_id "$WORK/out.json" >/dev/null 2>&1; then
        MODEL=$(jq -c .authorization_model_id "$WORK/out.json")
    else
        MODEL=$m
    fi
}

model_json() {  # label json: a model the DSL can't express
    local m=$MODEL
    MODEL=null
    call "$1" authorization-models "$2" '.authorization_model_id'
    MODEL=$m
}

new_store
model_json 'model: a bytes parameter (JSON; the DSL has no bytes)' \
    '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"cc"}]}}}}],"conditions":{"cc":{"name":"cc","expression":"size(b) > 0","parameters":{"b":{"type_name":"TYPE_NAME_BYTES"}}}}}'
model_json 'model: condition key differs from its name' \
    '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"cc"}]}}}}],"conditions":{"cc":{"name":"dd","expression":"x < 1","parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}'
model_json 'model: map parameter without its generic type' \
    '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"cc"}]}}}}],"conditions":{"cc":{"name":"cc","expression":"size(m) > 0","parameters":{"m":{"type_name":"TYPE_NAME_MAP"}}}}}'
model 'model: CEL syntax error' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with cx]
condition cx(x: int) {
  x <
}
M
model 'model: undeclared identifier in expression' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with cx]
condition cx(x: int) {
  y < 100
}
M
model 'model: non-bool expression' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with cx]
condition cx(x: int) {
  x + 1
}
M
model 'model: type error (int < string)' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with cx]
condition cx(x: int) {
  x < "a"
}
M
model 'model: int < double (no implicit conversion)' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with cx]
condition cx(x: int) {
  x < 1.5
}
M

# The main probe model.
new_store
# The DSL has no `any` parameter type: doc#anyp and condition cany are patched in.
model 'main model' '.type_definitions |= map(if .type == "doc" then .relations.anyp = {"this": {}} | .metadata.relations.anyp = {"directly_related_user_types": [{"type": "user", "condition": "cany"}]} else . end) | .conditions.cany = {"name": "cany", "expression": "a == 1", "parameters": {"a": {"type_name": "TYPE_NAME_ANY"}}}' <<'M'
model
  schema 1.1
type user
type group
  relations
    define member: [user]
type doc
  relations
    define viewer: [user with cx, group#member with cx]
    define orview: [user with cor]
    define rev: [user with crev]
    define listy: [user with clist]
    define ts: [user with cts]
    define mapy: [user with cmap]
condition cx(x: int) {
  x < 100
}
condition cor(x: int, y: int) {
  x < 100 || 10 / y == 1
}
condition crev(x: int, y: int) {
  10 / y == 1 || x < 100
}
condition clist(l: list<string>) {
  l.exists(e, e == "zzz")
}
condition cts(t: timestamp, d: duration) {
  t + d > timestamp("2023-01-01T00:00:00Z")
}
condition cmap(m: map<int>) {
  m.a > 1
}
M
call 'write: tuple doc:t, context {x:10}' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:t","condition":{"name":"cx","context":{"x":10}}}]}}' '"written"'
call 'check doc:t: tuple x=10, request x=200 (who wins)' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:t"},"context":{"x":200}}' .allowed
call 'write: undefined condition' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:u","condition":{"name":"nope"}}]}}' '"written"'
call 'write: context key not a parameter' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:u","condition":{"name":"cx","context":{"z":1}}}]}}' '"written"'
call 'write: context value of the wrong type' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:u","condition":{"name":"cx","context":{"x":"abc"}}}]}}' '"written"'
call 'write: no condition where only "with c" is allowed' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:u"}]}}' '"written"'
call 'write: condition on an unconditioned restriction' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"member","object":"group:g","condition":{"name":"cx"}}]}}' '"written"'
call 'write: same key again, other context' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:t","condition":{"name":"cx","context":{"x":20}}}]}}' '"written"'
call 'write: same key again, other context, on_duplicate ignore' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:t","condition":{"name":"cx","context":{"x":20}}}],"on_duplicate":"ignore"}}' '"written"'
call 'read: doc:t' read '{"tuple_key":{"object":"doc:t"}}' '[.tuples[].key]'
call 'delete: doc:t without naming the condition' write \
    '{"deletes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:t"}]}}' '"deleted"'
call 'write: the probe tuples' write \
    '{"writes":{"tuple_keys":[
        {"user":"user:jon","relation":"viewer","object":"doc:1","condition":{"name":"cx"}},
        {"user":"group:x#member","relation":"viewer","object":"doc:2","condition":{"name":"cx"}},
        {"user":"user:jon","relation":"orview","object":"doc:1","condition":{"name":"cor"}},
        {"user":"user:jon","relation":"rev","object":"doc:1","condition":{"name":"crev"}},
        {"user":"user:jon","relation":"listy","object":"doc:1","condition":{"name":"clist"}},
        {"user":"user:jon","relation":"ts","object":"doc:1","condition":{"name":"cts"}},
        {"user":"user:jon","relation":"mapy","object":"doc:1","condition":{"name":"cmap"}},
        {"user":"user:jon","relation":"anyp","object":"doc:1","condition":{"name":"cany"}}]}}' '"written"'
for v in '10' '"10"' '10.0' '10.5' 'true' '1e30' '-5' '"0x10"' '"1e1"'; do
    call "check: int param given $v" check \
        '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:1"},"context":{"x":'"$v"'}}' .allowed
done
call 'check: double given 1.8e+309 as a JSON number' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:1"},"context":{"x":1.79769313486231570814527423731704356798070e+309}}' .allowed
call 'check: request context with an extra key' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:1"},"context":{"x":10,"other":1}}' .allowed
call 'check: request context null' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:1"},"context":{"x":null}}' .allowed
call 'check doc:2: userset edge errors, user not in group' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:2"},"context":{}}' .allowed
call 'check doc:2: same, user is the userset itself' check \
    '{"tuple_key":{"user":"group:x#member","relation":"viewer","object":"doc:2"},"context":{}}' .allowed
call 'listobjects ann (no tuples; doc:2 userset edge errors)' list-objects \
    '{"type":"doc","relation":"viewer","user":"user:ann","context":{}}' .objects
call 'listobjects group:x#member, no context' list-objects \
    '{"type":"doc","relation":"viewer","user":"group:x#member","context":{}}' .objects
call 'listusers doc:2 (edge errors, nobody behind it)' list-users \
    '{"object":{"type":"doc","id":"2"},"relation":"viewer","user_filters":[{"type":"user"}],"context":{}}' .users
call 'check: x<100 || 10/y==1, x=10 y=0' check \
    '{"tuple_key":{"user":"user:jon","relation":"orview","object":"doc:1"},"context":{"x":10,"y":0}}' .allowed
call 'check: x<100 || 10/y==1, x=200 y=0' check \
    '{"tuple_key":{"user":"user:jon","relation":"orview","object":"doc:1"},"context":{"x":200,"y":0}}' .allowed
call 'check: 10/y==1 || x<100, x=10 y=0' check \
    '{"tuple_key":{"user":"user:jon","relation":"rev","object":"doc:1"},"context":{"x":10,"y":0}}' .allowed
call 'check: exists over 3 strings' check \
    '{"tuple_key":{"user":"user:jon","relation":"listy","object":"doc:1"},"context":{"l":["a","b","zzz"]}}' .allowed
call 'check: exists over 50 strings (cost limit 100)' check \
    "$(jq -nc '{tuple_key:{user:"user:jon",relation:"listy",object:"doc:1"},context:{l:[range(50) | "a"]}}')" .allowed
call 'check: exists over 200 strings (cost limit 100)' check \
    "$(jq -nc '{tuple_key:{user:"user:jon",relation:"listy",object:"doc:1"},context:{l:[range(200) | "a"]}}')" .allowed
call 'check: list<string> given a number element' check \
    '{"tuple_key":{"user":"user:jon","relation":"listy","object":"doc:1"},"context":{"l":["a",1]}}' .allowed
call 'check: timestamp + duration, d="1h"' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2022-12-31T23:30:00Z","d":"1h"}}' .allowed
call 'check: duration "1d" (not a Go duration)' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2022-12-31T23:30:00Z","d":"1d"}}' .allowed
call 'check: duration "1h30m"' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2022-12-31T22:45:00Z","d":"1h30m"}}' .allowed
call 'check: timestamp without seconds' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2023-10-11T11:00.000Z","d":"1h"}}' .allowed
call 'check: timestamp with offset +02:00' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2023-01-01T01:30:00+02:00","d":"1h"}}' .allowed
call 'check: timestamp lower-case t and z' check \
    '{"tuple_key":{"user":"user:jon","relation":"ts","object":"doc:1"},"context":{"t":"2023-01-01t01:30:00z","d":"1h"}}' .allowed
call 'check: map<int> m.a, present' check \
    '{"tuple_key":{"user":"user:jon","relation":"mapy","object":"doc:1"},"context":{"m":{"a":2}}}' .allowed
call 'check: map<int> m.a, key absent' check \
    '{"tuple_key":{"user":"user:jon","relation":"mapy","object":"doc:1"},"context":{"m":{"b":2}}}' .allowed
call 'check: any a == 1, a=1' check \
    '{"tuple_key":{"user":"user:jon","relation":"anyp","object":"doc:1"},"context":{"a":1}}' .allowed
call 'check: any a == 1, a="1"' check \
    '{"tuple_key":{"user":"user:jon","relation":"anyp","object":"doc:1"},"context":{"a":"1"}}' .allowed

# Contextual tuples with a bad condition: Check versus the lists.
call 'check: contextual tuple with an undefined condition' check \
    '{"tuple_key":{"user":"user:ann","relation":"viewer","object":"doc:9"},"contextual_tuples":{"tuple_keys":[{"user":"user:ann","relation":"viewer","object":"doc:9","condition":{"name":"nope"}}]},"context":{"x":1}}' .allowed
call 'listobjects: contextual tuple with an undefined condition' list-objects \
    '{"type":"doc","relation":"viewer","user":"user:ann","contextual_tuples":{"tuple_keys":[{"user":"user:ann","relation":"viewer","object":"doc:9","condition":{"name":"nope"}}]},"context":{"x":1}}' .objects
call 'check: contextual tuple with a wrongly typed context' check \
    '{"tuple_key":{"user":"user:ann","relation":"viewer","object":"doc:9"},"contextual_tuples":{"tuple_keys":[{"user":"user:ann","relation":"viewer","object":"doc:9","condition":{"name":"cx","context":{"x":"abc"}}}]},"context":{"x":1}}' .allowed
call 'check: contextual tuple, its context x=1 wins over request x=500' check \
    '{"tuple_key":{"user":"user:ann","relation":"viewer","object":"doc:9"},"contextual_tuples":{"tuple_keys":[{"user":"user:ann","relation":"viewer","object":"doc:9","condition":{"name":"cx","context":{"x":1}}}]},"context":{"x":500}}' .allowed

# Stored tuple contexts that a newer model's condition no longer accepts.
call 'write: doc:s with context {x:10}, doc:k with context {x:10}' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"viewer","object":"doc:s","condition":{"name":"cx","context":{"x":10}}},{"user":"user:jon","relation":"viewer","object":"doc:k","condition":{"name":"cx","context":{"x":10}}}]}}' '"written"'
model 'model 2: cx(x: string)' <<'M'
model
  schema 1.1
type user
type group
  relations
    define member: [user]
type doc
  relations
    define viewer: [user with cx, group#member with cx]
condition cx(x: string) {
  x == "a"
}
M
call 'check doc:s under model 2: stored x=10 is not a string' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:s"},"context":{"x":"a"}}' .allowed
call 'listobjects under model 2 (doc:s, doc:k: stored x=10)' list-objects \
    '{"type":"doc","relation":"viewer","user":"user:jon","context":{"x":"a"}}' .objects
model 'model 3: cx(y: int), no parameter x' <<'M'
model
  schema 1.1
type user
type group
  relations
    define member: [user]
type doc
  relations
    define viewer: [user with cx, group#member with cx]
condition cx(y: int) {
  y < 100
}
M
call 'check doc:k under model 3: stored context key x is not a parameter' check \
    '{"tuple_key":{"user":"user:jon","relation":"viewer","object":"doc:k"},"context":{"y":1}}' .allowed

# Numeric conversions of request context values (types/converters.go).
new_store
model 'model 4: double and uint parameters' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define dbl: [user with cd]
    define uns: [user with cu]
condition cd(x: double) {
  x > 0.0
}
condition cu(x: uint) {
  x > 5u
}
M
call 'write: dbl and uns tuples' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"dbl","object":"doc:1","condition":{"name":"cd"}},{"user":"user:jon","relation":"uns","object":"doc:1","condition":{"name":"cu"}}]}}' '"written"'
for v in '0.1' '"0.1"' '"1.5"' '1' '"1e400"'; do
    call "check: double param given $v" check \
        '{"tuple_key":{"user":"user:jon","relation":"dbl","object":"doc:1"},"context":{"x":'"$v"'}}' .allowed
done
for v in '10' '-1' '"10"' '1e19' '18446744073709551615'; do
    call "check: uint param given $v" check \
        '{"tuple_key":{"user":"user:jon","relation":"uns","object":"doc:1"},"context":{"x":'"$v"'}}' .allowed
done

# Phase 4, steps 3 to 6 (P33 to P44 in designs/d-conditions.md): the request's
# validation of conditions, what the type checker accepts, the cost limit's
# threshold, the no-parameter quirk, getters and Read.
new_store
model_json 'P33 model: condition name with a colon' \
  '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"a:b"}]}}}}],"conditions":{"a:b":{"name":"a:b","expression":"x < 1","parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}'
model_json 'P33 model: expression over 512 bytes' \
  "$(jq -nc --arg e "$(printf 'x == 1 || %.0s' $(seq 1 60))x == 2" '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":$e,"parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}')"
model_json 'P33 model: 26 parameters' \
  "$(jq -nc '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":"p1 < 1","parameters":([range(26)] | map({key: ("p" + tostring), value: {"type_name":"TYPE_NAME_INT"}}) | from_entries)}}}')"
model_json 'P34 model: conditional with branches of two types' \
  '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":"(x > 1 ? 1 : \"a\") == 1","parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}'
model_json 'P35 model: an any parameter alone as the expression' \
  '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":"a","parameters":{"a":{"type_name":"TYPE_NAME_ANY"}}}}}'
model_json 'P36 model: a list literal of mixed types' \
  '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":"size([1, \"a\"]) == x","parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}'
model_json 'P37 model: dyn(x) < 1.5' \
  '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"type":"doc","relations":{"viewer":{"this":{}}},"metadata":{"relations":{"viewer":{"directly_related_user_types":[{"type":"user","condition":"c1"}]}}}}],"conditions":{"c1":{"name":"c1","expression":"dyn(x) < 1.5","parameters":{"x":{"type_name":"TYPE_NAME_INT"}}}}}'
model 'main model for P38 to P44' '.type_definitions |= map(if .type == "doc" then .relations.anyp = {"this": {}} | .metadata.relations.anyp = {"directly_related_user_types": [{"type": "user", "condition": "cany"}]} | .relations.nop = {"this": {}} | .metadata.relations.nop = {"directly_related_user_types": [{"type": "user", "condition": "cnone"}]} else . end) | .conditions.cany = {"name": "cany", "expression": "a < 5", "parameters": {"a": {"type_name": "TYPE_NAME_ANY"}}} | .conditions.cnone = {"name": "cnone", "expression": "true"}' <<'M'
model
  schema 1.1
type user
type doc
  relations
    define listy: [user with clist]
    define one: [user with cx]
    define orx: [user with cor]
    define acc: [user with cacc]
condition clist(l: list<string>) {
  l.exists(e, e == "zzz")
}
condition cx(x: int) {
  x < 100
}
condition cor(x: int) {
  x == 1 || x == 2 || x == 3 || x == 4 || x == 5 || x == 6 || x == 7 || x == 8 || x == 9 || x == 10 || x == 11 || x == 12 || x == 13 || x == 14 || x == 15 || x == 16 || x == 17 || x == 18 || x == 19 || x == 20 || x == 21 || x == 22 || x == 23 || x == 24 || x == 25 || x == 26 || x == 27 || x == 28 || x == 29 || x == 30 || x == 31 || x == 32 || x == 33 || x == 34 || x == 35
}
condition cacc(t: timestamp) {
  t.getHours("Europe/Paris") == 12 && t.getHours("+02:00") == 12 && t.getDayOfWeek() == 0 && t.getMonth() == 6
}
M
call 'write: the probe tuples' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"listy","object":"doc:1","condition":{"name":"clist"}},{"user":"user:jon","relation":"one","object":"doc:1","condition":{"name":"cx"}},{"user":"user:jon","relation":"nop","object":"doc:1","condition":{"name":"cnone"}},{"user":"user:jon","relation":"orx","object":"doc:1","condition":{"name":"cor"}},{"user":"user:jon","relation":"acc","object":"doc:1","condition":{"name":"cacc"}},{"user":"user:jon","relation":"anyp","object":"doc:1","condition":{"name":"cany"}}]}}' '"written"'
for n in 10 20 25 30 40; do
    call "P38 check: exists over $n strings (cost limit 100)" check \
        "$(jq -nc --argjson n $n '{tuple_key:{user:"user:jon",relation:"listy",object:"doc:1"},context:{l:[range($n) | "a"]}}')" .allowed
done
call 'P38 check: a 35-term || chain, all false' check '{"tuple_key":{"user":"user:jon","relation":"orx","object":"doc:1"},"context":{"x":99}}' .allowed
call 'P39 check: no-parameter condition, empty context' check '{"tuple_key":{"user":"user:jon","relation":"nop","object":"doc:1"}}' .allowed
call 'P39 check: no-parameter condition, context {z:1}' check '{"tuple_key":{"user":"user:jon","relation":"nop","object":"doc:1"},"context":{"z":1}}' .allowed
call 'P40 check: getters with a zone and an offset' check '{"tuple_key":{"user":"user:jon","relation":"acc","object":"doc:1"},"context":{"t":"2024-07-07T10:00:00Z"}}' .allowed
call 'P41 check: any a < 5 given 3 (a double against an int)' check '{"tuple_key":{"user":"user:jon","relation":"anyp","object":"doc:1"},"context":{"a":3}}' .allowed
call 'P42 read: a condition written without context' read '{"tuple_key":{"object":"doc:1","relation":"one","user":"user:jon"}}' '[.tuples[].key]'
call 'P43 write: a one-character condition name in a tuple' write \
    '{"writes":{"tuple_keys":[{"user":"user:ann","relation":"one","object":"doc:1","condition":{"name":"c"}}]}}' '"written"'
call 'P44 write: the same key and condition, on_duplicate ignore' write \
    '{"writes":{"tuple_keys":[{"user":"user:jon","relation":"listy","object":"doc:1","condition":{"name":"clist"}}],"on_duplicate":"ignore"}}' '"written"'
call 'check: context is an array' check '{"tuple_key":{"user":"user:jon","relation":"one","object":"doc:1"},"context":[1]}' .allowed
