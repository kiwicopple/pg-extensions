# Helpers for test/run.sh and bench/pn-counter.sh. Source, don't execute.
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

    PGCRDT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt.XXXXXX")
    trap stop_cluster EXIT INT TERM

    "$PGBIN/initdb" -D "$PGCRDT_TMP/data" -U postgres -A trust --no-sync >"$PGCRDT_TMP/initdb.log" 2>&1 || {
        cat "$PGCRDT_TMP/initdb.log" >&2
        exit 2
    }
    # Preload pg_tle when this Postgres has it, so 03_install can test the
    # pgtle.install_extension path (it skips otherwise).
    local tle_opt=
    if [ -x "$PGBIN/pg_config" ] && [ -f "$("$PGBIN/pg_config" --sharedir)/extension/pg_tle.control" ]; then
        tle_opt="-c shared_preload_libraries=pg_tle"
    fi
    "$PGBIN/pg_ctl" -D "$PGCRDT_TMP/data" -l "$PGCRDT_TMP/server.log" -w \
        -o "-c listen_addresses='' -k $PGCRDT_TMP -c fsync=off -c full_page_writes=off $tle_opt ${PG_EXTRA_OPTS:-}" \
        start >/dev/null || {
        cat "$PGCRDT_TMP/server.log" >&2
        exit 2
    }

    export PGHOST=$PGCRDT_TMP PGPORT=5432 PGUSER=postgres
    unset PGPASSWORD PGDATABASE
    ADMIN_DB=postgres
}

stop_cluster() {
    if [ -n "${PGCRDT_TMP:-}" ] && [ -d "$PGCRDT_TMP/data" ]; then
        "$PGBIN/pg_ctl" -D "$PGCRDT_TMP/data" -m immediate stop >/dev/null 2>&1 || true
    fi
    case "${PGCRDT_TMP:-}" in
        */pgcrdt.*) rm -rf "$PGCRDT_TMP" ;;
    esac
    PGCRDT_TMP=
}

# The client roles of the PostgREST convention (anon, authenticated, as on
# Supabase), so 02_security can check grants to them. Nothing else needs them.
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
