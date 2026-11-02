# Shared helpers for test/run.sh and bench/run.sh. Source, don't execute.
#
# By default starts a throwaway Postgres cluster in a temp directory that
# listens only on a Unix socket (no TCP port, so it never clashes with a
# running server) and deletes it on exit. With EXTERNAL=1, uses the server
# described by the usual libpq variables (PGHOST, PGPORT, PGUSER, ...); that
# user must be able to create databases and roles.

find_pgbin() {
    if [ -n "${PGBIN:-}" ]; then
        :
    elif command -v initdb >/dev/null 2>&1; then
        PGBIN=$(dirname "$(command -v initdb)")
    elif [ -x /Applications/Postgres.app/Contents/Versions/latest/bin/initdb ]; then
        PGBIN=/Applications/Postgres.app/Contents/Versions/latest/bin
    elif command -v psql >/dev/null 2>&1; then
        PGBIN=$(dirname "$(command -v psql)")
    else
        echo "error: can't find Postgres binaries; set PGBIN" >&2
        exit 2
    fi
    export PGBIN
}

export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"

psql_admin() {
    "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "${ADMIN_DB:-postgres}" "$@"
}

start_cluster() {
    find_pgbin
    if [ "${EXTERNAL:-0}" = 1 ]; then
        ADMIN_DB=${PGDATABASE:-postgres}
        return
    fi

    PGPERM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgperm.XXXXXX")
    trap stop_cluster EXIT INT TERM

    "$PGBIN/initdb" -D "$PGPERM_TMP/data" -U postgres -A trust --no-sync >"$PGPERM_TMP/initdb.log" 2>&1 || {
        cat "$PGPERM_TMP/initdb.log" >&2
        exit 2
    }
    "$PGBIN/pg_ctl" -D "$PGPERM_TMP/data" -l "$PGPERM_TMP/server.log" -w \
        -o "-c listen_addresses='' -k $PGPERM_TMP -c fsync=off -c full_page_writes=off ${PG_EXTRA_OPTS:-}" \
        start >/dev/null || {
        cat "$PGPERM_TMP/server.log" >&2
        exit 2
    }

    export PGHOST=$PGPERM_TMP PGPORT=5432 PGUSER=postgres
    unset PGPASSWORD PGDATABASE
    ADMIN_DB=postgres
}

stop_cluster() {
    if [ -n "${PGPERM_TMP:-}" ] && [ -d "$PGPERM_TMP/data" ]; then
        "$PGBIN/pg_ctl" -D "$PGPERM_TMP/data" -m immediate stop >/dev/null 2>&1 || true
    fi
    case "${PGPERM_TMP:-}" in
        */pgperm.*) rm -rf "$PGPERM_TMP" ;;
    esac
    PGPERM_TMP=
}

# Supabase's client roles, so tests and benchmarks run under RLS the same way.
ensure_roles() {
    psql_admin <<'SQL'
do $$
declare r text;
begin
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
        if not exists (select 1 from pg_roles where rolname = r) then
            execute format('create role %I nologin', r);
        end if;
    end loop;
end $$;
SQL
}

# Resolve an --impl argument relative to the extension directory.
resolve_impl() {
    case "$1" in
        /*) echo "$1" ;;
        *) if [ -f "$1" ]; then echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
           else echo "$EXT_DIR/$1"; fi ;;
    esac
}
