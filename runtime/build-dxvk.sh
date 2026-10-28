#!/bin/bash
# Builds CodeWeavers' DXVK (1.10.3, from the CrossOver source drop) for 32- and 64-bit Windows
# with mingw-w64, into $BUILD/dxvk-install/{i386,x86_64}-windows. The DLLs get Wine's builtin
# marker (as CrossOver's do) so Wine loads them from the runtime's lib/dxvk folder.
#
# Usage: build-dxvk.sh          apply Stepover's patches and build
#        build-dxvk.sh patch    only apply the patches
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"   # absolute: patch -d changes folder before reading the patch
source "$HERE/config.sh"

export PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SRC="$SOURCES/sources/dxvk"
OUT="$BUILD/dxvk-install"
if [ ! -f "$SRC/meson.build" ]; then
    tar -xzf "$DL/crossover-sources-${CX_VERSION}.tar.gz" -C "$SOURCES" sources/dxvk
fi
for p in "$HERE"/patches/dxvk/*.patch; do   # -N: already applied is fine
    patch -d "$SRC" -p1 -N -s -i "$p" || true
done
grep -q 'Stepover build fix' "$SRC/src/d3d9/d3d9_include.h" || { echo "dxvk patches did not apply" >&2; exit 1; }
[ "${1:-}" != patch ] || exit 0
rm -rf "$OUT"
# DXVK 1.10.3 predates GCC 13, whose C++ library stopped including <cstdint> indirectly.
for arch in 64 32; do
    dir="$BUILD/dxvk-build$arch"
    rm -rf "$dir"
    meson setup "$dir" "$SRC" --cross-file "$SRC/build-win$arch.txt" --buildtype release -Dcpp_args="-include cstdint" \
        --prefix "$dir/install" --bindir "$( [ $arch = 64 ] && echo x86_64 || echo i386 )-windows" \
        -Denable_tests=false
    ninja -C "$dir" install
    mkdir -p "$OUT"
    cp -R "$dir/install/$( [ $arch = 64 ] && echo x86_64 || echo i386 )-windows" "$OUT/"
done
for f in "$OUT"/*/*.dll; do "$TOOLS/tools/winebuild/winebuild" --builtin "$f"; done
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "dxvk $(cat "$SRC/RELEASE" 2>/dev/null || echo 1.10.3) installed in $OUT"
ls -R "$OUT"
