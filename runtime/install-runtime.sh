#!/bin/bash
# Assembles the Stepover runtime in $RUNTIMES/$RUNTIME_NAME from the Wine build, the x86_64 host
# libraries, Stepover's compat plug-in, Apple's D3DMetal (from the Game Porting Toolkit disk image, or
# with STEPOVER_D3DMETAL_ARCHIVE from a published Stepover runtime archive, which is how CI gets it),
# upstream DXMT, and Wine Mono/Gecko. The previous runtime is kept as <name>.old for rollback.
#
#   lib/wine/x86_64-unix/cxcompatdb.so   Stepover's per-program graphics picker (../compat)
#   lib/d3dmetal/{external,wine}          D3DMetal, nvngx-on-metalfx renamed per Apple's Read Me
#   lib/dxmt/{i386,x86_64}-windows, x86_64-unix
set -euo pipefail
source "$(dirname "$0")/config.sh"

[ -x "$INSTALL/lib/wine/x86_64-unix/wine" ] || { echo "no Wine build, run build-wine.sh" >&2; exit 1; }
[ -n "${STEPOVER_D3DMETAL_ARCHIVE:-}" ] || [ -f "$GPTK_DMG" ] || { echo "no Game Porting Toolkit disk image at $GPTK_DMG" >&2; exit 1; }

DEST="$RUNTIMES/$RUNTIME_NAME"
STAGE="$DEST.new"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"

echo "== Wine"
# -p keeps wine.inf's mtime: a new one makes Wine redo every bottle's setup on next launch.
cp -Rp "$INSTALL/lib/wine" "$STAGE/lib/wine"
cp -Rp "$INSTALL/share/wine" "$STAGE/share/wine"
# bin/wine must stay a symlink: the CrossOver loader looks for ntdll.so next to realpath(self).
ln -s ../lib/wine/x86_64-unix/wine "$STAGE/bin/wine"
for cand in "$INSTALL/bin/wineserver" "$INSTALL/lib/wine/x86_64-unix/wineserver"; do
    [ -e "$cand" ] && { cp -L "$cand" "$STAGE/bin/wineserver"; break; }
done
[ -x "$STAGE/bin/wineserver" ] || { echo "missing wineserver" >&2; exit 1; }
cp -a "$DEPS"/lib/*.dylib "$STAGE/lib/"

echo "== compat plug-in"
clang -arch x86_64 -shared -O2 -Wall -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$SOURCES/sources/wine/include" -DWINE_UNIX_LIB \
    -o "$STAGE/lib/wine/x86_64-unix/cxcompatdb.so" "$SRC_ROOT/compat/stepovercompat.c" \
    "$STAGE/lib/wine/x86_64-unix/ntdll.so" -Wl,-rpath,@loader_path -install_name @rpath/cxcompatdb.so

echo "== D3DMetal"
if [ -n "${STEPOVER_D3DMETAL_ARCHIVE:-}" ]; then
    # CI can't download the Game Porting Toolkit; a published runtime already carries D3DMetal.
    FROM="$(mktemp -d "${TMPDIR:-/tmp}/stepover-d3dmetal.XXXX")"
    tar -xJf "$STEPOVER_D3DMETAL_ARCHIVE" -C "$FROM" --include='*/lib/d3dmetal/*' --include='*/licenses/d3dmetal/*' 2>/dev/null || true
    LIB="$(find "$FROM" -mindepth 3 -maxdepth 3 -type d -path '*/lib/d3dmetal' | head -1)"
    LIC="$(find "$FROM" -mindepth 3 -maxdepth 3 -type d -path '*/licenses/d3dmetal' | head -1)"
    if [ -z "$LIB" ] || [ -z "$LIC" ]; then
        rm -rf "$FROM"; echo "no D3DMetal in $STEPOVER_D3DMETAL_ARCHIVE" >&2; exit 1
    fi
    ditto "$LIB" "$STAGE/lib/d3dmetal"
    ditto "$LIC" "$STAGE/licenses/d3dmetal"
    rm -rf "$FROM"
else
    MNT="$(mktemp -d "${TMPDIR:-/tmp}/stepover-gptk.XXXX")"
    INNER="$(mktemp -d "${TMPDIR:-/tmp}/stepover-gptk-inner.XXXX")"
    cleanup() { hdiutil detach "$INNER" >/dev/null 2>&1 || true; hdiutil detach "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" "$INNER" 2>/dev/null || true; }
    trap cleanup EXIT
    hdiutil attach -readonly -nobrowse -noverify -mountpoint "$MNT" "$GPTK_DMG" >/dev/null
    EVAL="$(find "$MNT" -maxdepth 1 -name 'Evaluation environment*.dmg' | head -1)"
    [ -n "$EVAL" ] || { echo "no evaluation environment inside $GPTK_DMG" >&2; exit 1; }
    hdiutil attach -readonly -nobrowse -noverify -mountpoint "$INNER" "$EVAL" >/dev/null
    mkdir -p "$STAGE/lib/d3dmetal"
    ditto "$INNER/redist/lib/external" "$STAGE/lib/d3dmetal/external"
    ditto "$INNER/redist/lib/wine" "$STAGE/lib/d3dmetal/wine"
    mkdir -p "$STAGE/licenses/d3dmetal"
    cp "$INNER/License.rtf" "$INNER/Acknowledgements.rtf" "$STAGE/licenses/d3dmetal/"
    cleanup; trap - EXIT
fi
for f in x86_64-unix/nvngx-on-metalfx.so x86_64-windows/nvngx-on-metalfx.dll; do
    [ -e "$STAGE/lib/d3dmetal/wine/$f" ] && mv "$STAGE/lib/d3dmetal/wine/$f" "$STAGE/lib/d3dmetal/wine/${f/nvngx-on-metalfx/nvngx}"
done
D3DM_VERSION="$(plutil -extract CFBundleVersion raw "$STAGE/lib/d3dmetal/external/D3DMetal.framework/Resources/Info.plist")"

echo "== DXMT $DXMT_VERSION"
fetch "https://github.com/3Shain/dxmt/releases/download/v$DXMT_VERSION/dxmt-v$DXMT_VERSION-builtin.tar.gz" \
    8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d "dxmt-v$DXMT_VERSION-builtin.tar.gz"
mkdir -p "$STAGE/lib/dxmt"
tar -xzf "$DL/dxmt-v$DXMT_VERSION-builtin.tar.gz" -C "$STAGE/lib/dxmt" --strip-components=1
[ -d "$STAGE/lib/dxmt/x86_64-windows" ] || { echo "unexpected DXMT layout" >&2; ls "$STAGE/lib/dxmt" >&2; exit 1; }

echo "== DXVK"
if [ -d "$BUILD/dxvk-install/x86_64-windows" ]; then
    mkdir -p "$STAGE/lib/dxvk"
    cp -R "$BUILD/dxvk-install/x86_64-windows" "$BUILD/dxvk-install/i386-windows" "$STAGE/lib/dxvk/"
    DXVK_VERSION="$(grep -o "version : 'v[0-9.]*'" "$SOURCES/sources/dxvk/meson.build" | head -1 | tr -dc '0-9.')"
else
    echo "no DXVK build (run build-dxvk.sh); the dxvk backend will fall back to WineD3D"
    DXVK_VERSION=none
fi

echo "== Wine Mono / Gecko"
fetch "https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.tar.xz" \
    "$MONO_SHA256" "wine-mono-$MONO_VERSION-x86.tar.xz"
fetch "https://dl.winehq.org/wine/wine-gecko/$GECKO_VERSION/wine-gecko-$GECKO_VERSION-x86.tar.xz" \
    "$GECKO_X86_SHA256" "wine-gecko-$GECKO_VERSION-x86.tar.xz"
fetch "https://dl.winehq.org/wine/wine-gecko/$GECKO_VERSION/wine-gecko-$GECKO_VERSION-x86_64.tar.xz" \
    "$GECKO_X64_SHA256" "wine-gecko-$GECKO_VERSION-x86_64.tar.xz"
mkdir -p "$STAGE/share/wine/mono" "$STAGE/share/wine/gecko"
tar -xJf "$DL/wine-mono-$MONO_VERSION-x86.tar.xz" -C "$STAGE/share/wine/mono"
tar -xJf "$DL/wine-gecko-$GECKO_VERSION-x86.tar.xz" -C "$STAGE/share/wine/gecko"
tar -xJf "$DL/wine-gecko-$GECKO_VERSION-x86_64.tar.xz" -C "$STAGE/share/wine/gecko"

echo "== licenses"
L="$STAGE/licenses"
mkdir -p "$L/wine" "$L/gnutls" "$L/gmp" "$L/freetype" "$L/nettle" "$L/sdl2" "$L/ffmpeg" "$L/moltenvk" "$L/dxmt" "$L/dxvk"
cp "$SOURCES/sources/wine/COPYING.LIB" "$SOURCES/sources/wine/LICENSE" "$SOURCES/sources/wine/AUTHORS" "$L/wine/"
cp "$SOURCES/sources/gnutls/gnutls/LICENSE" "$L/gnutls/" 2>/dev/null || true
cp "$SOURCES/sources/gnutls/gmp/COPYING.LESSERv3" "$SOURCES/sources/gnutls/gmp/COPYINGv2" "$SOURCES/sources/gnutls/gmp/COPYINGv3" "$L/gmp/"
cp "$SOURCES/sources/freetype/LICENSE.TXT" "$SOURCES/sources/freetype/docs/FTL.TXT" "$L/freetype/"
tar -xzOf "$DL/nettle-3.10.2.tar.gz" nettle-3.10.2/COPYING.LESSERv3 > "$L/nettle/COPYING.LESSERv3"
tar -xzOf "$DL/SDL2-2.32.10.tar.gz" SDL2-2.32.10/LICENSE.txt > "$L/sdl2/LICENSE.txt"
tar -xJOf "$DL/ffmpeg-7.1.5.tar.xz" ffmpeg-7.1.5/COPYING.LGPLv2.1 > "$L/ffmpeg/COPYING.LGPLv2.1"
tar -xOf "$DL/MoltenVK-1.4.2-macos.tar" MoltenVK/LICENSE > "$L/moltenvk/LICENSE"
fetch "https://raw.githubusercontent.com/3Shain/dxmt/v$DXMT_VERSION/LICENSE" \
    6b928413c6308c106f3e0080bd94b6427b56d587d400fd40e6cbfbab7d9c4ae1 "dxmt-v$DXMT_VERSION-LICENSE"
cp "$DL/dxmt-v$DXMT_VERSION-LICENSE" "$L/dxmt/LICENSE"
[ -f "$BUILD/dxvk-install/LICENSE" ] && cp "$BUILD/dxvk-install/LICENSE" "$L/dxvk/LICENSE"
cat > "$L/NOTICE.txt" <<EOF
Stepover Wine runtime $RUNTIME_NAME

Not made, endorsed or supported by CodeWeavers or Apple. "CrossOver" is a registered trademark
of CodeWeavers, Inc.

Wine (LGPL-2.1-or-later, wine/): built unmodified from CodeWeavers' published CrossOver
$CX_VERSION source, $CX_URL (sha256 $CX_SHA256).
The same archive is attached to every Stepover release, with the build scripts that produced this
runtime (GPL-3.0). gnutls, gmp, freetype and DXVK ($DXVK_VERSION) come from the same archive; DXVK
carries two header fixes for newer mingw-w64 (patches/dxvk in the Stepover source).
nettle 3.10.2, SDL 2.32.10 and FFmpeg 7.1.5 (LGPL build) were built from their release archives,
also attached to each release.

D3DMetal $D3DM_VERSION (d3dmetal/): Apple's Game Porting Toolkit redistributables, distributed
unmodified and only for non-commercial purposes under Apple's license (d3dmetal/License.rtf);
Apple hardware only. The nvngx-on-metalfx files are renamed to nvngx as Apple's Read Me instructs.

DXMT $DXMT_VERSION (dxmt/, MIT): https://github.com/3Shain/dxmt, release builds used as published.
MoltenVK 1.4.2 (moltenvk/, Apache-2.0): https://github.com/KhronosGroup/MoltenVK, release build.
Wine Mono $MONO_VERSION and Wine Gecko $GECKO_VERSION: WineHQ's release builds as published; sources
and licenses at https://gitlab.winehq.org/mono/wine-mono and https://gitlab.winehq.org/wine/wine-gecko.
EOF

echo "== signatures and checks"
find "$STAGE/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -not -path '*/d3dmetal/*' -exec codesign -f -s - {} \; 2>/dev/null
codesign -f -s - "$STAGE/bin/wineserver" "$STAGE/lib/wine/x86_64-unix/wine" 2>/dev/null || true
if otool -L "$STAGE"/lib/*.dylib "$STAGE"/lib/wine/x86_64-unix/*.so | grep -q "$BUILD"; then
    echo "absolute build paths left in binaries" >&2; exit 1
fi
cat > "$STAGE/VERSION" <<EOF
name=$RUNTIME_NAME
build=$RUNTIME_BUILD
wine=$(cat "$SOURCES/sources/wine/VERSION")
crossover_sources=$CX_VERSION
d3dmetal=$D3DM_VERSION
dxmt=$DXMT_VERSION
dxvk=$DXVK_VERSION
built=$(date '+%Y-%m-%d %H:%M %Z')
EOF
WINEPREFIX="$STAGE/.version-check" "$STAGE/bin/wine" --version
rm -rf "$STAGE/.version-check"

if [ -d "$DEST" ]; then
    # Same wine.inf as the installed runtime: keep its date so bottles don't redo their setup.
    if cmp -s "$DEST/share/wine/wine.inf" "$STAGE/share/wine/wine.inf"; then
        touch -r "$DEST/share/wine/wine.inf" "$STAGE/share/wine/wine.inf"
    fi
    rm -rf "$DEST.old"; mv "$DEST" "$DEST.old"
fi
mv "$STAGE" "$DEST"
echo "runtime installed at $DEST"
cat "$DEST/VERSION"
