#!/usr/bin/env bash
# Run every vacuum / WAL benchmark and write results/*.md. About an hour on
# the benchmark machine; peak disk use about 15 GB (each script runs its own
# throwaway cluster under $TMPDIR). Two stages, scripts inside a stage in
# parallel (the rate-limited and size-only measurements do not depend on
# CPU; nothing here measures latency).
#
#   research/benchmarks/vacuum/run-all.sh
#   QUICK=1 research/benchmarks/vacuum/run-all.sh    # a few minutes, small counts
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/results"
LOGS=${LOGS:-$R/logs}
mkdir -p "$R" "$LOGS"

echo "stage 1: bloat, autovac (plain, yseq_, ydoc_)  logs in $LOGS"
"$HERE/bloat.sh" > "$LOGS/bloat.log" 2>&1 &
for s in plain a b; do
    SHAPES=$s OUT="$R/autovac-$s.md" "$HERE/autovac.sh" > "$LOGS/autovac-$s.log" 2>&1 &
done
wait

echo "stage 2: wal, ckpt, pn"
"$HERE/wal.sh" > "$LOGS/wal.log" 2>&1 &
"$HERE/ckpt.sh" > "$LOGS/ckpt.log" 2>&1 &
"$HERE/pn.sh" > "$LOGS/pn.log" 2>&1 &
wait
grep -h WARNING "$LOGS"/*.log || true
echo "done: $(ls "$R"/*.md | tr '\n' ' ')"
