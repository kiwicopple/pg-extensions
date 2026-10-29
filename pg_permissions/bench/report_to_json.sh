#!/usr/bin/env bash
# Convert bench/run.sh markdown reports to JSON for the docs site.
#
#   bench/report_to_json.sh bench/results/20261029-101500-c-compiled-model-large.md
#   bench/report_to_json.sh --environment local bench/baselines/[abc]-*-*.md
#
# Writes bench/baselines/data/<run_id>.json per report and prints its path.
# The schema is described in bench/baselines/data/README.md. bench/run.sh calls
# this after every complete run (not --only runs).
#
# Options:
#   --environment local|docker   default: $BENCH_ENVIRONMENT, else local
#   --host TEXT                  default: $BENCH_HOST, else the machine's CPU,
#                                CPU count and memory (sysctl or /proc)
#   --tag NAME                   appended to the run_id (e.g. smoke)
#   --date ISO-8601              default: the report's "Date:" line, read as
#                                local time of this machine, converted to UTC
#   --out DIR                    default: bench/baselines/data
#
# run_id is pg<major>-<environment>-<design>-<scale>-<shape>[-<tag>], so
# a later run with the same settings replaces the earlier file. A report that
# is itself in bench/baselines/ (a committed reference run) also gets a
# "report" field with its path from pg_permissions/, which the docs site
# links to as the raw report.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ENVIRONMENT=${BENCH_ENVIRONMENT:-local}
HOST_DESC=${BENCH_HOST:-}
TAG=
DATE=
OUT="$HERE/baselines/data"
REPORTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --environment) ENVIRONMENT=$2; shift 2 ;;
        --host) HOST_DESC=$2; shift 2 ;;
        --tag) TAG=$2; shift 2 ;;
        --date) DATE=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) REPORTS+=("$1"); shift ;;
    esac
done
[ ${#REPORTS[@]} -gt 0 ] || { echo "usage: $0 [options] REPORT.md..." >&2; exit 2; }
case "$ENVIRONMENT" in local|docker) ;; *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;; esac

if [ -z "$HOST_DESC" ]; then
    if [ "$(uname -s)" = Darwin ]; then
        HOST_DESC="$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
    else
        HOST_DESC="$(uname -m), $(nproc) CPU, $(awk '/^MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo) GB"
    fi
fi

md5_hex() { md5 -q 2>/dev/null || md5sum | cut -c1-32; }
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

mkdir -p "$OUT"
for report in "${REPORTS[@]}"; do
    [ -f "$report" ] || { echo "error: no such report: $report" >&2; exit 2; }

    # "# Benchmark: c-compiled-model (design c), large scale, default shape"
    read -r design scale shape < <(sed -n '1s/^# Benchmark: .* (design \([a-z]*\)), \([a-z]*\) scale, \([a-z]*\) shape$/\1 \2 \3/p' "$report")
    pg_version=$(sed -n 's/^- Postgres: \([^ ]*\).*/\1/p' "$report" | head -1)
    read -r duration clients < <(sed -n 's/^- pgbench: \([0-9]*\)s per workload, \([0-9]*\) clients.*/\1 \2/p' "$report" | head -1)
    report_date=$(sed -n 's/^- Date: //p' "$report" | head -1)
    if [ -z "${design:-}" ] || [ -z "$pg_version" ] || [ -z "${duration:-}" ] || [ -z "$report_date" ]; then
        echo "error: $report doesn't look like a bench/run.sh report" >&2
        exit 2
    fi
    major=$(printf '%s' "$pg_version" | sed 's/^\([0-9]*\).*/\1/')

    date_iso=$DATE
    [ -n "$date_iso" ] || date_iso=$(perl -MPOSIX -e '
        my ($y, $m, $d, $H, $M) = split /[- :]/, $ARGV[0];
        print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(mktime(0, $M, $H, $d, $m - 1, $y - 1900, 0, 0, -1)))' "$report_date")

    run_id="pg$major-$ENVIRONMENT-$design-$scale-$shape${TAG:+-$TAG}"

    # Per-policy checksum, as bench/run.sh prints it: md5 of the
    # "user<TAB>visible<TAB>md5" lines of the equivalence table, in report
    # order (by user); first 8 hex digits.
    checksums=""
    for policy in $(awk -F' \\| ' '/^\| policy \| user \| visible \| md5 \|/ { t = 1; next }
                                   t && /^\| ---/ { next }
                                   t && /^\|/ { sub(/^\| /, "", $1); if (!seen[$1]++) print $1; next }
                                   t { exit }' "$report"); do
        sum=$(awk -F' \\| ' -v p="$policy" '/^\| policy \| user \| visible \| md5 \|/ { t = 1; next }
                                   t && /^\| ---/ { next }
                                   t && /^\|/ { sub(/^\| /, "", $1); sub(/ \|$/, "", $4); if ($1 == p) printf "%s\t%s\t%s\n", $2, $3, $4; next }
                                   t { exit }' "$report" | md5_hex | cut -c1-8)
        checksums="$checksums${checksums:+, }$(json_str "$policy"): $(json_str "$sum")"
    done

    report_field=""
    report_abs="$(cd "$(dirname "$report")" && pwd)/$(basename "$report")"
    [ "$(dirname "$report_abs")" != "$HERE/baselines" ] ||
        report_field="$(json_str "bench/baselines/$(basename "$report_abs")")"

    out_file="$OUT/$run_id.json"
    awk -v run_id="$(json_str "$run_id")" -v date="$(json_str "$date_iso")" \
        -v env="$(json_str "$ENVIRONMENT")" -v host="$(json_str "$HOST_DESC")" \
        -v pgv="$(json_str "$pg_version")" -v design="$(json_str "$design")" \
        -v scale="$(json_str "$scale")" -v shape="$(json_str "$shape")" \
        -v clients="$clients" -v duration="$duration" -v checksums="$checksums" -v report="$report_field" '
        function num(v) { return (v ~ /^[0-9]+(\.[0-9]+)?$/) ? v + 0 : "null" }
        function cell(s) { gsub(/^ +| +$/, "", s); return s }
        /^\| workload \| p50 ms/ { tbl = "w"; next }
        /^\| phase \| seed s/    { tbl = "s"; next }
        /^\| ---/ { next }
        !/^\|/ { tbl = ""; next }
        tbl == "w" {
            n = split($0, c, "|")
            # | name | p50 | p95 | avg | tps | budget | status |
            w[++nw] = sprintf("    {\"name\": \"%s\", \"p50_ms\": %s, \"p95_ms\": %s, \"tps\": %s, \"budget_ms\": %s}",
                              cell(c[2]), num(cell(c[3])), num(cell(c[4])), num(cell(c[6])), num(cell(c[7])))
        }
        tbl == "s" {
            split($0, c, "|")
            # | phase | seconds | MB | rows |
            s[++ns] = sprintf("    {\"phase\": \"%s\", \"seconds\": %s, \"size_mb\": %s}",
                              cell(c[2]), num(cell(c[3])), num(cell(c[4])))
        }
        END {
            print "{"
            printf "  \"run_id\": %s,\n  \"date\": %s,\n  \"environment\": %s,\n  \"host\": %s,\n", run_id, date, env, host
            printf "  \"pg_version\": %s,\n  \"design\": %s,\n", pgv, design
            printf "  \"scale\": %s, \"shape\": %s, \"clients\": %d, \"duration_s\": %d,\n", scale, shape, clients, duration
            print "  \"workloads\": ["
            for (i = 1; i <= nw; i++) print w[i] (i < nw ? "," : "")
            print "  ],"
            print "  \"seeds\": ["
            for (i = 1; i <= ns; i++) print s[i] (i < ns ? "," : "")
            print "  ],"
            printf "  \"checksums\": {%s}%s\n", checksums, (report != "" ? "," : "")
            if (report != "") printf "  \"report\": %s\n", report
            print "}"
        }' "$report" > "$out_file"
    echo "$out_file"
done
