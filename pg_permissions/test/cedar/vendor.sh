#!/usr/bin/env bash
# Vendor Cedar's integration tests (cedar-policy/cedar-integration-tests) as
# normalized JSON cases: the handwritten tests/ (with sample-data/) and the
# generated corpus (corpus-tests.tar.gz). Every Cedar-text policy file and schema
# is translated to JSON by the official Cedar CLI of the same release, built
# from crates.io in a pinned Rust image and run without network access. Run
# once; the output is committed. Then run generate.py (see README.md).
#
#   test/cedar/vendor.sh                     # builds the CLI (a few minutes)
#   CEDAR_CLI_DIR=/path/to/bin test/cedar/vendor.sh   # reuse a built CLI (Linux binary `cedar`)
#
# Writes (relative to this directory):
#   cases/handwritten.jsonl        the handwritten tests, one per line
#   cases/corpus-NN.jsonl.gz       the corpus, sharded by the first hex digit of
#                                  the test name (gzip, mtime 0: reproducible)
#   upstream/tests/, upstream/sample-data/   verbatim copies (small, readable)
#   upstream/LICENSE, upstream/NOTICE        Apache-2.0, from the same commit
#   upstream/SOURCE                repository, commit, CLI, image, tarball hash
#
# The raw corpus (188 MB extracted) is not committed. convert.py documents the
# case format and the schema normalization.
#
# Needs git, docker and python3. The clone is untrusted data: it goes into a
# new empty temp directory and nothing from it is executed; the CLI reads it
# read-only with --network none, and convert.py runs with python3 -I.
set -euo pipefail

REPO=https://github.com/cedar-policy/cedar-integration-tests
SHA=b157547fb8856911b293b7214768922c731878de      # tag v4.14.0 (= release/4.14.x, 2026-10-19)
CEDAR_VERSION=4.14.0                                # cedar-policy-cli on crates.io
RUST_IMAGE=rust:1.89-slim-bookworm@sha256:d7fc7de78bb8c1469933aeecbf801314d30d7d6e9f0578bba4cfa285bfa37fe6
TARBALL_SHA256=67a3698263d2a4530464b88c3094e5930570862c7123362bd7e848b305ad20ec

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/src"
git -C "$WORK/src" init -q
git -C "$WORK/src" fetch -q --depth 1 "$REPO" "$SHA"
git -C "$WORK/src" checkout -q FETCH_HEAD
got=$(git -C "$WORK/src" rev-parse HEAD)
[ "$got" = "$SHA" ] || { echo "error: fetched $got, expected $SHA" >&2; exit 1; }
sum=$(shasum -a 256 "$WORK/src/corpus-tests.tar.gz" | cut -d' ' -f1)
[ "$sum" = "$TARBALL_SHA256" ] || { echo "error: corpus-tests.tar.gz is $sum, expected $TARBALL_SHA256" >&2; exit 1; }
cedar_sub=$(git -C "$WORK/src" ls-tree HEAD cedar | awk '{print $3}')
spec_sub=$(git -C "$WORK/src" ls-tree HEAD cedar-spec | awk '{print $3}')

# The tree convert.py reads: corpus-tests/, tests/, sample-data/.
mkdir "$WORK/root"
tar -xzf "$WORK/src/corpus-tests.tar.gz" -C "$WORK/root" --no-same-owner corpus-tests
cp -R "$WORK/src/tests" "$WORK/src/sample-data" "$WORK/root/"

# The Cedar CLI, built from crates.io (cargo install --locked uses its lockfile).
if [ -n "${CEDAR_CLI_DIR:-}" ]; then
    CLI=$CEDAR_CLI_DIR
else
    CLI="$WORK/cli"
    mkdir -p "$CLI"
    docker run --rm -v "$CLI:/out" "$RUST_IMAGE" \
        cargo install cedar-policy-cli --version "$CEDAR_VERSION" --locked --root /out >&2
    CLI="$CLI/bin"
fi
ver=$(docker run --rm --network none -v "$CLI:/cli:ro" "$RUST_IMAGE" /cli/cedar --version)
[ "$ver" = "cedar-policy-cli $CEDAR_VERSION" ] || { echo "error: CLI is '$ver', expected $CEDAR_VERSION" >&2; exit 1; }

# Translate every Cedar-text policy set and schema to JSON.
python3 -I "$HERE/convert.py" manifest "$WORK/root" > "$WORK/manifest.tsv"
mkdir "$WORK/trans"
cat > "$WORK/translate.sh" <<'SH'
set -eu
cd /in
while IFS='	' read -r kind src dst; do
    if [ "$kind" = policy ]; then
        /cli/cedar translate-policy --direction cedar-to-json -p "$src" > "/out/$dst"
    else
        /cli/cedar translate-schema --direction cedar-to-json-with-resolved-types -s "$src" > "/out/$dst"
    fi
done < /work/manifest.tsv
SH
docker run --rm --network none \
    -v "$CLI:/cli:ro" -v "$WORK/root:/in:ro" -v "$WORK/trans:/out" -v "$WORK:/work:ro" \
    "$RUST_IMAGE" sh /work/translate.sh

rm -f "$HERE"/cases/*.jsonl "$HERE"/cases/*.jsonl.gz
python3 -I "$HERE/convert.py" build "$WORK/root" "$WORK/trans" "$HERE/cases"

rm -rf "$HERE/upstream"
mkdir -p "$HERE/upstream"
cp -R "$WORK/src/tests" "$WORK/src/sample-data" "$HERE/upstream/"
cp "$WORK/src/LICENSE" "$WORK/src/NOTICE" "$HERE/upstream/"

cat > "$HERE/upstream/SOURCE" <<SRC
Repository: $REPO
Commit:     $SHA (tag v$CEDAR_VERSION, branch release/4.14.x)
Corpus:     corpus-tests.tar.gz, sha256 $TARBALL_SHA256
            generated from cedar $cedar_sub and cedar-spec $spec_sub (submodules)
License:    Apache-2.0 (upstream/LICENSE, upstream/NOTICE). Copyright Cedar Contributors.
Translated: Cedar-text policies and schemas to JSON with cedar-policy-cli $CEDAR_VERSION
            (crates.io, cargo install --locked) in $RUST_IMAGE
Vendored:   $(date -u +%Y-%m-%d) by test/cedar/vendor.sh

upstream/tests and upstream/sample-data are verbatim. cases/ is derived from
them and from the corpus by convert.py: one test per line, policies split per
policy id with their JSON form, entity and context JSON in the schema-free
(escaped) form, action entities from the schema added. Expectations are not
modified.
SRC
echo "vendored $(cat "$HERE"/cases/handwritten.jsonl | wc -l | tr -d ' ') handwritten tests and the corpus from $REPO@$SHA"
