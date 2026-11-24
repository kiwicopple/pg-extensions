#!/usr/bin/env bash
# Run only against a new, disposable cluster, with no TCP listener.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
MODES=(plain native upgrade tle tle-upgrade)
FILTER=
SELF_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            case "${2:-}" in
                plain|native|upgrade|tle|tle-upgrade) MODES=("$2"); shift 2 ;;
                *) echo 'Expected mode: plain, native, upgrade, tle, or tle-upgrade' >&2; exit 2 ;;
            esac ;;
        --filter) FILTER=${2:?Missing filter}; shift 2 ;;
        --self-test) SELF_ONLY=1; shift ;;
        -h|--help)
            echo 'run.sh [--mode plain|native|upgrade|tle|tle-upgrade] [--filter NAME] [--self-test]'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
PGBIN=${PGBIN:-$(pg_config --bindir)}
export PATH="$PGBIN:$PATH"
command -v pg_prove >/dev/null || { echo 'Install pg_prove (TAP::Parser::SourceHandler::pgTAP)' >&2; exit 2; }
export PERL5LIB="$HERE/lib${PERL5LIB:+:$PERL5LIB}"
VERSION=$(sed -n "s/^default_version *= *'\([^']*\)'.*/\1/p" "$EXT_DIR/pg_idkit.control")
[ -n "$VERSION" ] || { echo 'Missing default_version' >&2; exit 2; }
SPECS=()
for file in "$HERE"/spec/*.sql; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in *"$FILTER"*) SPECS+=("$file") ;; esac
done
[ "${#SPECS[@]}" -gt 0 ] || { echo "No specs match: $FILTER" >&2; exit 2; }
if [ -n "${IDKIT_ARTIFACT_DIR:-}" ]; then
    RESULTS=$IDKIT_ARTIFACT_DIR
    mkdir -p "$RESULTS"
else
    mkdir -p "$HERE/.results"
    RESULTS=$(mktemp -d "$HERE/.results/local.XXXXXX")
fi
TEST_TMP=$(mktemp -d /tmp/idkit.XXXXXX)
cleanup() {
    result=$?
    trap - EXIT
    if [ "$result" -ne 0 ]; then
        for log in start setup server; do
            if [ -f "$RESULTS/$log.log" ]; then
                echo "Failure context: $log.log" >&2
                tail -15 "$RESULTS/$log.log" >&2
            fi
        done
    fi
    "$PGBIN/pg_ctl" -D "$TEST_TMP/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$TEST_TMP"
    echo "Logs: $RESULTS"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Ignore inherited libpq settings, including PGHOSTADDR, which can override
# the socket path. This runner must never touch an existing server.
unset PGHOSTADDR PGSERVICE PGSERVICEFILE PGOPTIONS PGDATABASE PGPASSWORD PGCLIENTENCODING
export PGHOST="$TEST_TMP" PGPORT=5432 PGUSER=postgres PGPASSFILE="$TEST_TMP/pgpass"
: > "$PGPASSFILE"
chmod 600 "$PGPASSFILE"
"$PGBIN/initdb" -D "$TEST_TMP/data" -U postgres -A trust --no-sync >"$RESULTS/init.log" 2>&1
preload=
for mode in "${MODES[@]}"; do
    case "$mode" in tle*) preload='-c shared_preload_libraries=pg_tle' ;; esac
done
"$PGBIN/pg_ctl" -D "$TEST_TMP/data" -l "$RESULTS/server.log" -w \
    -o "-c listen_addresses='' -k $TEST_TMP -c fsync=off $preload" start >"$RESULTS/start.log" 2>&1
cd "$EXT_DIR"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c 'create role idkit_owner nosuperuser' >"$RESULTS/setup.log" 2>&1
createdb -O idkit_owner idkit_runner
psql -X -q -v ON_ERROR_STOP=1 -d idkit_runner -c 'create extension pgtap' >>"$RESULTS/setup.log" 2>&1
export PGDATABASE=idkit_runner
{
    psql -X -At -c 'select version(); select extname, extversion from pg_extension order by extname'
    pg_prove --version
} > "$RESULTS/versions.log"
bash "$HERE/self-test.sh" "$RESULTS/self-test" | tee "$RESULTS/self-test.log"
[ "$SELF_ONLY" = 0 ] || exit 0
status=0
for mode in "${MODES[@]}"; do
    database="idkit_${mode//-/_}"
    createdb -O idkit_owner "$database"
    plain=false; tle=false; upgrade=false; extension=pg_idkit
    case "$mode" in plain) plain=true ;; tle*) tle=true; extension=pg_idkit_tle ;; esac
    case "$mode" in *upgrade) upgrade=true ;; esac
    if ! psql -X -q -v ON_ERROR_STOP=1 -d "$database" \
        -v plain="$plain" -v tle="$tle" -v upgrade="$upgrade" -v extension="$extension" \
        -v version="$VERSION" -v old_version=0.0.4 \
        -v new_path="$EXT_DIR/pg_idkit--$VERSION.sql" \
        -v old_path="$EXT_DIR/pg_idkit--0.0.4.sql" \
        -v update_path="$EXT_DIR/pg_idkit--0.0.4--$VERSION.sql" \
        -f "$HERE/setup.sql" >"$RESULTS/$mode-setup.log" 2>&1; then
        cat "$RESULTS/$mode-setup.log" >&2
        status=1
        continue
    fi
    # Each file receives its own clone. SQL specs also roll back their changes.
    for file in "${SPECS[@]}"; do
        spec=$(basename "$file" .sql)
        target="${database}_${spec%%_*}"
        createdb -T "$database" -O idkit_owner "$target"
        echo "$mode / $spec"
        if ! pg_prove --norc --nocolor --harness IDKit::Harness --psql-bin "$PGBIN/psql" \
            --dbname "$target" --set ON_ERROR_STOP=1 "$file" 2>&1 | tee "$RESULTS/$mode-$spec.log"; then
            status=1
        fi
        dropdb "$target"
    done
    dropdb "$database"
done
exit "$status"
