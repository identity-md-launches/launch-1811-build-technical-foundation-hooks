#!/bin/sh
# Offline check of vendored sources. Run from the repository root.
#  1. Every vendored file matches the hash recorded for the tree as committed.
#  2. Every file differing from its upstream original is listed in docs/checksums/FORMAT_ONLY.txt
#     (forge fmt, line_length 120, applied to the upstream file; see docs/DEPENDENCIES.md).
set -eu
sha256sum -c --quiet docs/checksums/VENDORED.sha256
mkdir -p test/scratch
check_tmp=$(mktemp -d test/scratch/vendor-verify.XXXXXX)
trap 'rm -f "$check_tmp/up" "$check_tmp/ve"; rmdir "$check_tmp"' EXIT HUP INT TERM
sort -k2 docs/checksums/UPSTREAM.sha256 > "$check_tmp/up"
sort -k2 docs/checksums/VENDORED.sha256 > "$check_tmp/ve"
changed=$(join -j 2 "$check_tmp/up" "$check_tmp/ve" | awk '$2 != $3 {print $1}')
for f in $changed; do
  grep -qx "$f" docs/checksums/FORMAT_ONLY.txt || { echo "unexplained difference from upstream: $f"; exit 1; }
done
echo "vendored files verified: $(wc -l < docs/checksums/VENDORED.sha256) files, $(echo "$changed" | grep -c . || true) formatting-only differences"
