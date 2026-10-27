#!/bin/bash
# install-runtime.sh with STEPOVER_D3DMETAL_ARCHIVE takes D3DMetal from a published runtime archive.
# Needs a local Wine build and a released runtime archive; skipped where they don't exist (CI).
SRC_ROOT="$(bash -c 'source runtime/config.sh; echo "$SRC_ROOT"')"
ARCHIVE="$(ls "$SRC_ROOT"/release/dist/*/stepover-runtime-cx26.3.tar.xz 2>/dev/null | tail -1)"
INSTALLED="$HOME/Library/Application Support/Stepover/Runtimes/cx26.3"
if [ ! -x "$SRC_ROOT/build/wine-install/lib/wine/x86_64-unix/wine" ] || [ -z "$ARCHIVE" ] || [ ! -d "$INSTALLED" ]; then
    echo "skip test-d3dmetal (no local Wine build, released archive or installed runtime)"
    exit 0
fi

tmp=$(mktemp -d)
STEPOVER_D3DMETAL_ARCHIVE="$ARCHIVE" STEPOVER_RUNTIMES="$tmp/runtimes" STEPOVER_GPTK_DMG=/nonexistent \
    runtime/install-runtime.sh >"$tmp/log" 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "installs with D3DMetal from $(basename "$(dirname "$ARCHIVE")")'s runtime"
assert_eq "" "$(diff -r "$tmp/runtimes/cx26.3/lib/d3dmetal" "$INSTALLED/lib/d3dmetal" 2>&1)" "same D3DMetal as the installed runtime"
assert_eq "" "$(diff -r "$tmp/runtimes/cx26.3/licenses/d3dmetal" "$INSTALLED/licenses/d3dmetal" 2>&1)" "same D3DMetal licenses"
assert_eq "yes" "$(grep -q '^d3dmetal=[0-9]' "$tmp/runtimes/cx26.3/VERSION" 2>/dev/null && echo yes || echo no)" "VERSION names the D3DMetal version"

# Review Focus 3: a broken archive fails the install instead of producing a runtime without D3DMetal.
printf x > "$tmp/broken.tar.xz"
STEPOVER_D3DMETAL_ARCHIVE="$tmp/broken.tar.xz" STEPOVER_RUNTIMES="$tmp/runtimes2" STEPOVER_GPTK_DMG=/nonexistent \
    runtime/install-runtime.sh >"$tmp/log2" 2>&1 && status=0 || status=$?
assert_eq "1" "$status" "broken archive fails the install"
assert_eq "yes" "$(grep -q "no D3DMetal in $tmp/broken.tar.xz" "$tmp/log2" && echo yes || echo no)" "says which archive"
assert_eq "no" "$([ -e "$tmp/runtimes2/cx26.3" ] && echo yes || echo no)" "no runtime installed"
rm -rf "$tmp"
