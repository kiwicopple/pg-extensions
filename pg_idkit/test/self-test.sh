#!/usr/bin/env bash
# These deliberately broken SQL files must be rejected by the real runner.
set -euo pipefail
OUT=${1:?Output directory required}
mkdir -p "$OUT"
cat > "$OUT/pass.sql" <<'SQL'
begin;
select plan(1);
select pass('working control');
select * from finish();
rollback;
SQL
cat > "$OUT/assertion.sql" <<'SQL'
select plan(1);
select fail('intentional failure');
SQL
cat > "$OUT/missing.sql" <<'SQL'
select plan(2);
select pass('only one assertion');
SQL
cat > "$OUT/extra.sql" <<'SQL'
select plan(1);
select pass('first');
select pass('unplanned second assertion');
SQL
cat > "$OUT/process.sql" <<'SQL'
select plan(1);
select pass('planned assertion passed');
select 1 / 0;
SQL
cat > "$OUT/fatal.sql" <<'SQL'
select plan(1);
select pass('planned assertion passed');
select pg_terminate_backend(pg_backend_pid());
SQL
cat > "$OUT/skip.sql" <<'SQL'
select plan(1);
select skip('unexpected skipped coverage', 1);
SQL
cat > "$OUT/skip_all.sql" <<'SQL'
select skip_all('unexpected missing dependency');
SQL
cat > "$OUT/todo.sql" <<'SQL'
select plan(1);
select todo('unexpected TODO', 1);
select fail('unimplemented test');
SQL
cat > "$OUT/malformed.sql" <<'SQL'
select '1..1';
select 'ok 2 - wrong assertion number';
SQL
printf "select 'no assertions';\n" > "$OUT/empty.sql"
for name in pass assertion missing extra process fatal skip skip_all todo malformed empty; do
    result=0
    pg_prove --norc --nocolor --harness IDKit::Harness --psql-bin "$(command -v psql)" \
        --dbname "$PGDATABASE" --set ON_ERROR_STOP=1 "$OUT/$name.sql" >"$OUT/$name.log" 2>&1 || result=$?
    if { [ "$name" = pass ] && [ "$result" -ne 0 ]; } || { [ "$name" != pass ] && [ "$result" -eq 0 ]; }; then
        cat "$OUT/$name.log" >&2
        echo "Runner self-test failed: $name (exit $result)" >&2
        exit 1
    fi
    echo "Runner self-test passed: $name"
done
