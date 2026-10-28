#!/bin/bash
# build-dxvk.sh patch: Stepover's DXVK patches apply to a fresh DXVK tree when the script is run by a
# relative path from the repository root, as CI runs it. Needs the cached CrossOver archive.
DL="$(bash -c 'source runtime/config.sh; echo "$DL"')"
if [ ! -f "$DL/crossover-sources-26.3.0.tar.gz" ]; then
    echo "skip test-dxvk (no cached CrossOver archive)"
    exit 0
fi
tmp=$(mktemp -d)
STEPOVER_SOURCES="$tmp" runtime/build-dxvk.sh patch >"$tmp/log" 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "patches apply to a fresh tree"
assert_eq "yes" "$(grep -q 'Stepover build fix' "$tmp/sources/dxvk/src/d3d9/d3d9_include.h" 2>/dev/null && echo yes || echo no)" "d3d9 header patched"
STEPOVER_SOURCES="$tmp" runtime/build-dxvk.sh patch >/dev/null 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "applying them again is fine"
rm -rf "$tmp"
