#!/usr/bin/env bash
# Run the pg_permissions test suite.
#
#   test/run.sh                                       # against the extension (pg_permissions--0.1.0.sql)
#   test/run.sh --impl prototypes/a-tuple-core.sql    # against a prototype
#   test/run.sh rbac                                  # only spec files whose name contains "rbac"
#   test/run.sh --design b --impl X.sql               # force the design (a|b|c|d|none)
#   test/run.sh -v                                    # show every assertion, not just failures
#   test/run.sh --external                            # use the server from PGHOST/PGPORT/PGUSER
#   test/run.sh --no-cedar-oracle                     # skip the generated Cedar oracle files
#
# Spec files in test/spec/ are the shared RBAC, RLS and install specs in the
# API the prototypes have (unprefixed create_role, has_permission, ...); they
# run for every design except d. The extension (design d) renamed that API
# (rbac_*, research/decision.md "API naming (session 5)") and runs its own copies in
# test/spec/d/. Files in test/spec/<design>/ use that design's native API and
# run only with it. --design defaults to the first letter of the --impl
# file name before a dash (a-tuple-core.sql -> a), "d" for the extension file
# (pg_permissions--*.sql); anything else is "none".
# Files from both directories are sorted by file name; patterns match both.
#
# Each spec file runs in a fresh database cloned from a template that has the
# implementation installed. Exit status is 0 only if every file passes.
#
# For the extension, test/spec/d/7[0-7]_cedar_oracle*.sql are generated from
# Cedar's integration tests before the run (python3 -I test/cedar/generate.py
# suite, about 4 seconds; git ignores them). Without python3 the files already
# there run as they are. --no-cedar-oracle skips them.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$HERE/lib/cluster.sh"

IMPL="pg_permissions--0.1.0.sql"
VERBOSE=0
EXTERNAL=0
DESIGN=
CEDAR_ORACLE=1
PATTERNS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) IMPL=$2; shift 2 ;;
        --impl=*) IMPL=${1#--impl=}; shift ;;
        --design) DESIGN=$2; shift 2 ;;
        --design=*) DESIGN=${1#--design=}; shift ;;
        --external) EXTERNAL=1; shift ;;
        --no-cedar-oracle) CEDAR_ORACLE=0; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done

IMPL=$(resolve_impl "$IMPL")
[ -f "$IMPL" ] || { echo "error: implementation not found: $IMPL" >&2; exit 2; }

if [ -z "$DESIGN" ]; then
    impl_base=$(basename "$IMPL" .sql)
    case "$impl_base" in
        [abc]-*) DESIGN=${impl_base%%-*} ;;
        pg_permissions--*) DESIGN=d ;;
        *) DESIGN=none ;;
    esac
fi
case "$DESIGN" in
    a|b|c|d|none) ;;
    *) echo "error: unknown design: $DESIGN (expected a, b, c, d or none)" >&2; exit 2 ;;
esac

# The generated Cedar oracle files (design d): regenerate them when this run
# would select any of them.
CEDAR_GLOB='7[0-7]_cedar_oracle*'
if [ "$DESIGN" = d ] && [ $CEDAR_ORACLE = 1 ]; then
    want=0
    [ ${#PATTERNS[@]} = 0 ] && want=1
    for p in ${PATTERNS[@]+"${PATTERNS[@]}"}; do
        case "70_cedar_oracle_00 71_cedar_oracle_text_00 72_cedar_oracle_overlay_00 74_cedar_oracle_reduced_00 77_cedar_oracle_parse_00" in *"$p"*) want=1 ;; esac
    done
    if [ $want = 1 ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -I "$HERE/cedar/generate.py" suite >/dev/null || { echo "error: test/cedar/generate.py suite failed" >&2; exit 2; }
        elif ! ls "$HERE"/spec/d/$CEDAR_GLOB >/dev/null 2>&1; then
            echo "warning: python3 not found and no generated Cedar oracle files: they are not run" >&2
        else
            echo "note: python3 not found: running the Cedar oracle files already generated" >&2
        fi
    fi
fi

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

# Shared specs plus the design's own, sorted by file name across both. Design
# d has its own copies of the shared specs (rbac_* names), so it skips them.
SHARED=("$HERE"/spec/*.sql)
[ "$DESIGN" = d ] && SHARED=()
SPECS=()
while IFS= read -r line; do SPECS+=("${line#*$'\t'}"); done < <(
    for f in ${SHARED[@]+"${SHARED[@]}"} "$HERE/spec/$DESIGN"/*.sql; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | LC_ALL=C sort -t $'\t' -k1,1)

for f in "${SPECS[@]}"; do
    name=$(basename "$f" .sql)
    # shellcheck disable=SC2254
    if [ $CEDAR_ORACLE = 0 ]; then case "$name" in $CEDAR_GLOB) continue ;; esac; fi
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
