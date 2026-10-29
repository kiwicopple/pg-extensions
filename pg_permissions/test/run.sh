#!/usr/bin/env bash
# Run the pg_permissions test suite.
#
#   test/run.sh                                       # against the extension (pg_permissions--0.0.1.sql)
#   test/run.sh --impl prototypes/a-tuple-core.sql    # against a prototype
#   test/run.sh rbac                                  # only spec files whose name contains "rbac"
#   test/run.sh --design b --impl X.sql               # force the design (a|b|c|d|none)
#   test/run.sh -v                                    # show every assertion, not just failures
#   test/run.sh --external                            # use the server from PGHOST/PGPORT/PGUSER
#
# Spec files in test/spec/ are engine-independent and run for every
# implementation. Files in test/spec/<design>/ use that design's native API
# and run only with it. --design defaults to the first letter of the --impl
# file name before a dash (a-tuple-core.sql -> a); anything else is "none".
# Files from both directories are sorted by file name; patterns match both.
#
# Each spec file runs in a fresh database cloned from a template that has the
# implementation installed. Exit status is 0 only if every file passes.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$HERE/lib/cluster.sh"

IMPL="pg_permissions--0.0.1.sql"
VERBOSE=0
EXTERNAL=0
DESIGN=
PATTERNS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) IMPL=$2; shift 2 ;;
        --impl=*) IMPL=${1#--impl=}; shift ;;
        --design) DESIGN=$2; shift 2 ;;
        --design=*) DESIGN=${1#--design=}; shift ;;
        --external) EXTERNAL=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done

IMPL=$(resolve_impl "$IMPL")
[ -f "$IMPL" ] || { echo "error: implementation not found: $IMPL" >&2; exit 2; }

if [ -z "$DESIGN" ]; then
    impl_base=$(basename "$IMPL" .sql)
    case "$impl_base" in
        [abcd]-*) DESIGN=${impl_base%%-*} ;;
        *) DESIGN=none ;;
    esac
fi
case "$DESIGN" in
    a|b|c|d|none) ;;
    *) echo "error: unknown design: $DESIGN (expected a, b, c, d or none)" >&2; exit 2 ;;
esac

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=; RED=; DIM=; RESET=; fi

start_cluster
ensure_roles

TEMPLATE=pgperm_template
psql_admin -c "drop database if exists $TEMPLATE" -c "create database $TEMPLATE"
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$HERE/lib/tap.sql" >/dev/null
if ! load_out=$("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$IMPL" 2>&1 >/dev/null); then
    echo "${RED}error: failed to install ${IMPL#$EXT_DIR/}${RESET}" >&2
    echo "$load_out" >&2
    exit 2
fi

echo "Implementation: ${IMPL#$EXT_DIR/} (design: $DESIGN)"
echo "Postgres:       $("$PGBIN/psql" -X -tA -d "$TEMPLATE" -c 'show server_version')"
echo

total_files=0; passed_files=0; total_planned=0; total_passed=0

# Shared specs plus the design's own, sorted by file name across both.
SPECS=()
while IFS= read -r line; do SPECS+=("${line#*$'\t'}"); done < <(
    for f in "$HERE"/spec/*.sql "$HERE/spec/$DESIGN"/*.sql; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | LC_ALL=C sort -t $'\t' -k1,1)

for f in "${SPECS[@]}"; do
    name=$(basename "$f" .sql)
    label=$name
    [ "$(dirname "$f")" = "$HERE/spec" ] || label="$DESIGN/$name"
    if [ ${#PATTERNS[@]} -gt 0 ]; then
        match=0
        for p in "${PATTERNS[@]}"; do case "$name" in *"$p"*) match=1 ;; esac; done
        [ $match = 1 ] || continue
    fi

    db="pgperm_t_${name}"
    psql_admin -c "drop database if exists \"$db\"" -c "create database \"$db\" template $TEMPLATE"
    out=$("$PGBIN/psql" -X -q -tA -v ON_ERROR_STOP=0 -v impl_path="$IMPL" -d "$db" -f "$f" 2>&1 || true)
    psql_admin -c "drop database if exists \"$db\"" 2>/dev/null || true

    planned=$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | head -1)
    planned=${planned:-0}
    passed=$(printf '%s\n' "$out" | grep -c '^ok ' || true)
    failed=$(printf '%s\n' "$out" | grep -c '^not ok ' || true)
    errors=$(printf '%s\n' "$out" | grep -c 'ERROR:' || true)
    missing=$((planned - passed - failed))
    [ $missing -lt 0 ] && missing=0

    total_files=$((total_files + 1))
    total_planned=$((total_planned + planned))
    total_passed=$((total_passed + passed))

    if [ "$planned" -gt 0 ] && [ "$failed" = 0 ] && [ "$errors" = 0 ] && [ "$missing" = 0 ]; then
        passed_files=$((passed_files + 1))
        printf '  %sPASS%s  %-30s %3s/%s\n' "$GREEN" "$RESET" "$label" "$passed" "$planned"
        if [ $VERBOSE = 1 ]; then
            printf '%s\n' "$out" | grep -E '^(ok|not ok|#)' | sed "s/^/        $DIM/;s/\$/$RESET/" || true
        fi
    else
        detail=""
        [ "$failed" -gt 0 ] && detail="$detail, $failed failed"
        [ "$missing" -gt 0 ] && detail="$detail, $missing not run"
        [ "$errors" -gt 0 ] && detail="$detail, $errors errors"
        [ "$planned" = 0 ] && detail="$detail, no plan"
        printf '  %sFAIL%s  %-30s %3s/%s  (%s)\n' "$RED" "$RESET" "$label" "$passed" "$planned" "${detail#, }"
        if [ $VERBOSE = 1 ]; then
            printf '%s\n' "$out" | grep -E '^(ok|not ok|#)|ERROR:' | sed 's/^/        /' || true
        else
            printf '%s\n' "$out" | grep -E -A3 '^not ok ' | grep -E '^(not ok|#)' | head -20 | sed 's/^/        /' || true
            printf '%s\n' "$out" | grep 'ERROR:' | head -3 | sed 's/^psql:[^:]*:/        line /' || true
        fi
    fi
done

echo
if [ $total_files = 0 ]; then
    echo "No spec files matched."
    exit 2
fi
summary="$passed_files/$total_files files, $total_passed/$total_planned assertions"
if [ $passed_files = $total_files ]; then
    echo "${GREEN}All passed${RESET}: $summary"
else
    echo "${RED}Failures${RESET}: $summary"
    exit 1
fi
