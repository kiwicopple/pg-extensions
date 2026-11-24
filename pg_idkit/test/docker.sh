#!/usr/bin/env bash
# Build ID kit's own images, then run its suite in disposable containers.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
VERSIONS=()
ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --) shift; ARGS=("$@"); break ;;
        13|16|17|18) VERSIONS+=("$1"); shift ;;
        *) echo "usage: $0 [13|16|17|18 ...] [-- run.sh options]" >&2; exit 2 ;;
    esac
done
[ "${#VERSIONS[@]}" -gt 0 ] || VERSIONS=(16 17 18)
mkdir -p "$HERE/.results"
RESULTS=$(mktemp -d "$HERE/.results/docker.XXXXXX")
status=0
for version in "${VERSIONS[@]}"; do
    case "$version" in
        13) tag=13.23-bookworm ;;
        16) tag=16.15-trixie ;;
        17) tag=17.11-trixie ;;
        18) tag=18.6-trixie ;;
    esac
    image="pg-idkit-test:$version"
    mkdir -p "$RESULTS/$version"
    echo "Building $image ($tag)"
    if ! docker build --build-arg "PG_TAG=$tag" --build-arg "PG_MAJOR=$version" \
        -t "$image" "$HERE/docker" >"$RESULTS/$version/build.log" 2>&1; then
        tail -40 "$RESULTS/$version/build.log" >&2
        status=1
        continue
    fi
    echo "Testing Postgres $version"
    if ! docker run --rm -v "$EXT_DIR:/pg_idkit:ro" -v "$RESULTS/$version:/results" \
        "$image" bash -c '
            set -e
            cp /pg_idkit/pg_idkit.control /pg_idkit/pg_idkit--*.sql "$(pg_config --sharedir)/extension/"
            install -d -o postgres -g postgres /tmp/idkit-results
            status=0
            gosu postgres env IDKIT_ARTIFACT_DIR=/tmp/idkit-results bash /pg_idkit/test/run.sh "$@" || status=$?
            cp -R /tmp/idkit-results/. /results/
            exit "$status"
        ' _ ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee "$RESULTS/$version/run.log"; then
        status=1
    fi
done
echo "Logs: $RESULTS"
exit "$status"
