#!/usr/bin/env bash
# Run the yseq_ (shape A) test suite.
#
#   experiments/text-column/test/run.sh             # every spec file
#   experiments/text-column/test/run.sh merge       # only spec files whose name contains "merge"
#   experiments/text-column/test/run.sh -v          # show every assertion
#   experiments/text-column/test/run.sh --impl x.sql # another build of impl.sql
#
# Same harness as test/run.sh: a throwaway cluster on a Unix socket in a temp
# directory (test/lib/cluster.sh), lib/tap.sql, pg_crdt--0.0.1.sql and then
# impl.sql in a template database, and each spec file in a fresh clone.
# Spec files get :ext_dir (pg_crdt/) and :exp_dir (this experiment) as psql
# variables. Exit status is 0 only if every file passes.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXP_DIR=$(dirname "$HERE")
EXT_DIR=$(cd "$EXP_DIR/../.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"

VERBOSE=0
EXTERNAL=0
IMPL="$EXP_DIR/impl.sql"
PATTERNS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --external) EXTERNAL=1; shift ;;
        --impl) IMPL=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=; RED=; DIM=; RESET=; fi

start_cluster
ensure_roles
export PATH="$PGBIN:$PATH"
export PGCLIENTENCODING=UTF8

TEMPLATE=yseq_template
psql_admin -c "drop database if exists $TEMPLATE" -c "create database $TEMPLATE encoding 'UTF8' template template0"
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$EXT_DIR/test/lib/tap.sql" >/dev/null
for f in "$EXT_DIR/pg_crdt--0.0.1.sql" "$IMPL"; do
    if ! load_out=$("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$f" 2>&1 >/dev/null); then
        echo "${RED}error: failed to install ${f#$EXT_DIR/}${RESET}" >&2
        echo "$load_out" >&2
        exit 2
    fi
done

echo "Implementation: ${IMPL#$EXT_DIR/} (after pg_crdt--0.0.1.sql)"
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

    db="yseq_t_${name}"
    psql_admin -c "drop database if exists \"$db\"" -c "create database \"$db\" template $TEMPLATE"
    out=$("$PGBIN/psql" -X -q -tA -v ON_ERROR_STOP=0 -v ext_dir="$EXT_DIR" -v exp_dir="$EXP_DIR" -d "$db" -f "$f" 2>&1 || true)
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
