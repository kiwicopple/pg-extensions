#!/usr/bin/env bash
# Run the shape B (ydoc_) test suite. Adapted from pg_crdt/test/run.sh.
#
#   experiments/text-table/test/run.sh              # all spec files
#   experiments/text-table/test/run.sh basics       # files whose name contains "basics"
#   experiments/text-table/test/run.sh -v           # print every assertion
#   experiments/text-table/test/run.sh --impl x.sql # another build of impl.sql
#
# Starts a throwaway cluster (pg_crdt/test/lib/cluster.sh: temp dir, Unix
# socket only), loads tap.sql, the extension and impl.sql into a template, and
# runs each spec file in a fresh clone. Exit status 0 only if every file passes.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXP_DIR=$(dirname "$HERE")
EXT_DIR=$(cd "$EXP_DIR/../.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"

IMPL="$EXP_DIR/impl.sql"
VERBOSE=0
EXTERNAL=0
PATTERNS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) IMPL=$2; shift 2 ;;
        --impl=*) IMPL=${1#--impl=}; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done
case "$IMPL" in /*) ;; *) IMPL="$(pwd)/$IMPL" ;; esac
[ -f "$IMPL" ] || { echo "error: implementation not found: $IMPL" >&2; exit 2; }

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=; RED=; DIM=; RESET=; fi

start_cluster
export PATH="$PGBIN:$PATH"

TEMPLATE=ydoc_template
psql_admin -c "drop database if exists $TEMPLATE" -c "create database $TEMPLATE encoding 'UTF8' template template0"
for f in "$EXT_DIR/test/lib/tap.sql" "$EXT_DIR/pg_crdt--0.0.1.sql" "$IMPL"; do
    if ! load_out=$("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$f" 2>&1 >/dev/null); then
        echo "${RED}error: failed to load $f${RESET}" >&2
        echo "$load_out" >&2
        exit 2
    fi
done

echo "Implementation: ${IMPL#$EXT_DIR/}"
echo "Postgres:       $("$PGBIN/psql" -X -tA -d "$TEMPLATE" -c 'show server_version')"
echo

total_files=0; passed_files=0; total_planned=0; total_passed=0

for f in "$HERE"/spec/*.sql; do
    name=$(basename "$f" .sql)
    if [ ${#PATTERNS[@]} -gt 0 ]; then
        match=0
        for p in "${PATTERNS[@]}"; do case "$name" in *"$p"*) match=1 ;; esac; done
        [ $match = 1 ] || continue
    fi

    db="ydoc_t_${name}"
    psql_admin -c "drop database if exists \"$db\"" -c "create database \"$db\" template $TEMPLATE"
    out=$(PGCLIENTENCODING=UTF8 "$PGBIN/psql" -X -q -tA -v ON_ERROR_STOP=0 -v exp_dir="$EXP_DIR" -d "$db" -f "$f" 2>&1 || true)
    psql_admin -c "drop database if exists \"$db\" with (force)" 2>/dev/null || true

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
        printf '  %sPASS%s  %-30s %3s/%s\n' "$GREEN" "$RESET" "$name" "$passed" "$planned"
        if [ $VERBOSE = 1 ]; then
            printf '%s\n' "$out" | grep -E '^(ok|not ok|#)' | sed "s/^/        $DIM/;s/\$/$RESET/" || true
        fi
    else
        detail=""
        [ "$failed" -gt 0 ] && detail="$detail, $failed failed"
        [ "$missing" -gt 0 ] && detail="$detail, $missing not run"
        [ "$errors" -gt 0 ] && detail="$detail, $errors errors"
        [ "$planned" = 0 ] && detail="$detail, no plan"
        printf '  %sFAIL%s  %-30s %3s/%s  (%s)\n' "$RED" "$RESET" "$name" "$passed" "$planned" "${detail#, }"
        if [ $VERBOSE = 1 ]; then
            printf '%s\n' "$out" | grep -E '^(ok|not ok|#)|ERROR:' | sed 's/^/        /' || true
        else
            printf '%s\n' "$out" | grep -E -A3 '^not ok ' | grep -E '^(not ok|#)' | head -20 | sed 's/^/        /' || true
            printf '%s\n' "$out" | grep -E -A2 'ERROR:' | head -9 | sed 's/^psql:[^:]*:/        line /' || true
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
