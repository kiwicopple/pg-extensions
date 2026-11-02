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
#   test/run.sh --upgrade-from 0.0.1                  # install 0.0.1, apply the upgrade script, run every spec
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
# --upgrade-from V builds the template from pg_permissions--V.sql plus the
# upgrade script pg_permissions--V--<version of --impl>.sql instead, so the
# whole suite runs against an upgraded install. For the extension,
# tools/sync-upgrade.sh --check runs first and counts as a file: the upgrade
# script must hold the install file's marked sections.
#
# For the extension, test/spec/d/7[0-7]_cedar_oracle*.sql are generated from
# Cedar's integration tests before the run (python3 -I test/cedar/generate.py
# suite, about 9 seconds; git ignores them). Without python3 the files already
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
UPGRADE_FROM=
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
        --upgrade-from) UPGRADE_FROM=$2; shift 2 ;;
        --upgrade-from=*) UPGRADE_FROM=${1#--upgrade-from=}; shift ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# --upgrade-from V: the template gets pg_permissions--V.sql, then the upgrade
# script to the version of --impl, both from the directory of --impl.
INSTALL=("$IMPL")
if [ -n "$UPGRADE_FROM" ]; then
    impl_version=$(basename "$IMPL" .sql)
    impl_version=${impl_version#pg_permissions--}
    case "$(basename "$IMPL")" in
        pg_permissions--*.sql) ;;
        *) echo "error: --upgrade-from needs an extension file (pg_permissions--<version>.sql) as --impl" >&2; exit 2 ;;
    esac
    INSTALL=("$(dirname "$IMPL")/pg_permissions--$UPGRADE_FROM.sql"
             "$(dirname "$IMPL")/pg_permissions--$UPGRADE_FROM--$impl_version.sql")
    for f in "${INSTALL[@]}"; do
        [ -f "$f" ] || { echo "error: --upgrade-from $UPGRADE_FROM: not found: $f" >&2; exit 2; }
    done
fi

# The generated Cedar oracle files (design d): regenerate them when this run
# would select any of them.
CEDAR_GLOB='7[0-7]_cedar_oracle*'
if [ "$DESIGN" = d ] && [ $CEDAR_ORACLE = 1 ]; then
    want=0
    [ ${#PATTERNS[@]} = 0 ] && want=1
    for p in ${PATTERNS[@]+"${PATTERNS[@]}"}; do
        case "70_cedar_oracle_00 71_cedar_oracle_text_00 72_cedar_oracle_overlay_00 74_cedar_oracle_reduced_00 76_cedar_oracle_templates_00 77_cedar_oracle_parse_00" in *"$p"*) want=1 ;; esac
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
for f in "${INSTALL[@]}"; do
    if ! load_out=$("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$TEMPLATE" -f "$f" 2>&1 >/dev/null); then
        echo "${RED}error: failed to install ${f#$EXT_DIR/}${RESET}" >&2
        echo "$load_out" >&2
        exit 2
    fi
done

installed=
for f in "${INSTALL[@]}"; do installed="${installed:+$installed + }${f#$EXT_DIR/}"; done
echo "Implementation: $installed (design: $DESIGN)"
echo "Postgres:       $("$PGBIN/psql" -X -tA -d "$TEMPLATE" -c 'show server_version')"
echo

total_files=0; passed_files=0; total_planned=0; total_passed=0

# The extension: the upgrade script must hold the install file's marked
# sections (tools/sync-upgrade.sh). One file, one assertion.
# It runs unless name patterns select no file of that name.
sync_check=0
if [ "$DESIGN" = d ] && [ "$(basename "$IMPL")" = pg_permissions--0.1.0.sql ] && [ -x "$EXT_DIR/tools/sync-upgrade.sh" ] \
   && [ "$(dirname "$IMPL")" = "$EXT_DIR" ]; then
    sync_check=1
    if [ ${#PATTERNS[@]} -gt 0 ]; then
        sync_check=0
        for p in "${PATTERNS[@]}"; do case "sync-upgrade" in *"$p"*) sync_check=1 ;; esac; done
    fi
fi
if [ $sync_check = 1 ]; then
    total_files=$((total_files + 1)); total_planned=$((total_planned + 1))
    if sync_out=$("$EXT_DIR/tools/sync-upgrade.sh" --check 2>&1); then
        passed_files=$((passed_files + 1)); total_passed=$((total_passed + 1))
        printf '  %sPASS%s  %-30s %3s/%s\n' "$GREEN" "$RESET" "tools/sync-upgrade --check" 1 1
    else
        printf '  %sFAIL%s  %-30s %3s/%s  (%s)\n' "$RED" "$RESET" "tools/sync-upgrade --check" 0 1 "out of date"
        printf '%s\n' "$sync_out" | sed 's/^/        /'
    fi
fi

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
