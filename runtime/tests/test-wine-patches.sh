#!/bin/bash
# build-wine.sh patch: Stepover's Wine patches apply to a fresh CrossOver tree, and again without harm.
# Needs the cached CrossOver archive; only the files the patches touch are extracted.
DL="$(bash -c 'source runtime/config.sh; echo "$DL"')"
if [ ! -f "$DL/crossover-sources-26.3.0.tar.gz" ]; then
    echo "skip test-wine-patches (no cached CrossOver archive)"
    exit 0
fi
tmp=$(mktemp -d)
tar -xzf "$DL/crossover-sources-26.3.0.tar.gz" -C "$tmp" sources/wine/configure sources/wine/dlls/mmdevapi
STEPOVER_SOURCES="$tmp" runtime/build-wine.sh patch >"$tmp/log" 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "wine patches apply to a fresh tree"
assert_eq "yes" "$(grep -q 'downmix_stereo = TRUE' "$tmp/sources/wine/dlls/mmdevapi/spatialaudio.c" && echo yes || echo no)" \
    "spatial audio mixes down to stereo"
STEPOVER_SOURCES="$tmp" runtime/build-wine.sh patch >"$tmp/log" 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "applying them again is fine"
assert_eq "1" "$(grep -c 'downmix_stereo = TRUE' "$tmp/sources/wine/dlls/mmdevapi/spatialaudio.c")" "applied once"
assert_eq "" "$(find "$tmp/sources" -name '*.rej' -o -name '*.orig')" "no reject or backup files left"
rm -rf "$tmp"
