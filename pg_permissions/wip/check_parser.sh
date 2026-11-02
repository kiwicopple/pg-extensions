#!/usr/bin/env bash
# The parser oracle of Cedar phase 3 (research/plan-cedar.md): every Cedar-text
# policy of the vendored corpus (test/cedar/cases, corpus and handwritten
# tests) must parse to exactly the EST that cedar-policy-cli 4.14.0 wrote for
# it (jsonb equality, so key order does not matter).
#
#   wip/check_parser.sh              # throwaway cluster (PGBIN as for test/run.sh)
#   EXTERNAL=1 wip/check_parser.sh   # the server from PGHOST/PGPORT/PGUSER
#   wip/check_parser.sh -v           # also list every mismatch, not just 20
#
# It installs pg_permissions--0.1.0.sql, loads wip/cedar_parser.sql, and checks:
#   1. each policy alone with _cedar_parse_policy (5,708 policies), and
#   2. each test's policies joined into one text with _cedar_parse_policies,
#      against {"staticPolicies": {id: EST}, "templates": {}, "templateLinks": []}
#      (the ids are policy0, policy1, ... in order, as the CLI assigns them).
# U+0000 is replaced with U+E000 first, as generate.py does for the suite.
# Then it times the parse of the largest policy, of the median-size and the
# 90th-percentile-size ones, and of the whole corpus, and runs the negative
# spec wip/cedar_parser_spec.sql. Exit status 0 only if every check is equal
# and every assertion of the spec passes.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$EXT_DIR/test/lib/cluster.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cedar_parser.XXXXXX")
cleanup() {
    rm -rf "$WORK"
    if [ "${EXTERNAL:-0}" = 1 ]; then
        psql_admin -c "drop database if exists cedar_parser_check" -c "drop database if exists cedar_parser_check_spec" || true
    fi
    stop_cluster
}
trap cleanup EXIT INT TERM

python3 -I -B - "$EXT_DIR/test/cedar" "$WORK" <<'PY'
import csv, json, sys
sys.path.insert(0, sys.argv[1])
import generate as g
out = sys.argv[2]
pol = csv.writer(open(f'{out}/policies.csv', 'w', newline='', encoding='utf-8'))
sets = csv.writer(open(f'{out}/sets.csv', 'w', newline='', encoding='utf-8'))
for c in g.load_cases():
    ps = [p for p in c['policies'] if p.get('text') is not None]
    if not ps:
        continue
    want = {}
    for p in ps:
        text, est = g.sub_nul_text(p['text']), g.sub_nul(p['est'])
        pol.writerow([c['name'], p['id'], text, g.jtext(est)])
        want[p['id']] = est
    if [p['id'] for p in ps] == [f'policy{i}' for i in range(len(ps))]:
        sets.writerow([c['name'], '\n'.join(g.sub_nul_text(p['text']) for p in ps),
                       g.jtext({'staticPolicies': want, 'templates': {}, 'templateLinks': []})])
PY

DB=cedar_parser_check
psql_admin -c "drop database if exists $DB" -c "create database $DB"
run_psql() { "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
run_psql -f "$EXT_DIR/pg_permissions--0.1.0.sql" >/dev/null
run_psql -f "$HERE/cedar_parser.sql" >/dev/null

out=$(run_psql -v verbose="$VERBOSE" <<SQL
\pset footer off
create table policies (name text, id text, src text, est jsonb);
create table sets (name text, src text, want jsonb);
\copy policies from '$WORK/policies.csv' with (format csv)
\copy sets from '$WORK/sets.csv' with (format csv)

create function pg_temp.try_parse(src text, single boolean)
returns jsonb
language plpgsql
as \$\$
begin
    if single then
        return permissions._cedar_parse_policy(src);
    end if;
    return permissions._cedar_parse_policies(src);
exception when others then
    return jsonb_build_object('__error', sqlerrm, 'sqlstate', sqlstate);
end;
\$\$;

create table got_policies as select name, id, est, pg_temp.try_parse(src, true) as got from policies;
create table got_sets as select name, want, pg_temp.try_parse(src, false) as got from sets;

\echo
\echo 'EST equality'
select 'policies (_cedar_parse_policy)' as "check", count(*) filter (where got = est) as equal, count(*) as total,
       count(*) filter (where got ? '__error') as errors from got_policies
union all
select 'policy sets (_cedar_parse_policies)', count(*) filter (where got = want), count(*),
       count(*) filter (where got ? '__error') from got_sets;

\echo 'Mismatches'
select name, id, coalesce(got ->> '__error', 'EST differs') as problem
from got_policies where got is distinct from est
order by name, id
limit case when :verbose = 1 then null else 20 end;

\echo 'Parse time (best of 20 runs each)'
create function pg_temp.time_parse(src text)
returns numeric
language plpgsql
as \$\$
declare
    t0 timestamptz;
    best numeric;
    e jsonb;
begin
    for i in 1..20 loop
        t0 := clock_timestamp();
        e := permissions._cedar_parse_policy(src);
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    return round(best, 2);
end;
\$\$;
with sized as (
    select name, id, src, octet_length(src) as bytes,
           row_number() over (order by octet_length(src) desc) as big,
           row_number() over (order by octet_length(src)) as small,
           count(*) over () as n
    from policies)
select case when big = 1 then 'largest' when small = (n + 1) / 2 then 'median' else 'p90' end as policy, name, id, bytes,
       pg_temp.time_parse(src) as ms
from sized where big = 1 or small = (n + 1) / 2 or small = (n * 9) / 10
order by bytes desc;

select clock_timestamp() as t0 \gset
select count(permissions._cedar_parse_policy(src)) as parsed from policies;
select round(extract(epoch from clock_timestamp() - :'t0'::timestamptz) * 1000) as all_ms \gset
\echo 'Parse time, all policies once:' :all_ms 'ms'

select count(*) filter (where got is distinct from est) + (select count(*) filter (where got is distinct from want) from got_sets) as failures
from got_policies \gset
\echo 'Result: failures=':failures
SQL
)
printf '%s\n' "$out"
case "$out" in
    *'Result: failures=0'*) echo "All equal." ;;
    *) echo "FAIL: some policies do not parse to the CLI's EST." >&2; exit 1 ;;
esac

# The negative spec (TAP), in a fresh database with the TAP functions.
psql_admin -c "drop database if exists ${DB}_spec" -c "create database ${DB}_spec"
DB=${DB}_spec
run_psql -f "$EXT_DIR/test/lib/tap.sql" >/dev/null
run_psql -f "$EXT_DIR/pg_permissions--0.1.0.sql" >/dev/null
run_psql -f "$HERE/cedar_parser.sql" >/dev/null
spec=$("$PGBIN/psql" -X -q -tA -d "$DB" -f "$HERE/cedar_parser_spec.sql" 2>&1 || true)
planned=$(printf '%s\n' "$spec" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | head -1)
passed=$(printf '%s\n' "$spec" | grep -c '^ok ' || true)
echo
echo "Negative spec: $passed/${planned:-0} assertions pass"
if [ "${planned:-0}" = 0 ] || [ "$passed" != "$planned" ]; then
    printf '%s\n' "$spec" | grep -E -A3 '^not ok |ERROR:' | head -40
    exit 1
fi
