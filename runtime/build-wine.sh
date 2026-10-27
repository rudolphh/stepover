#!/bin/bash
# Builds CodeWeavers' CrossOver Wine tree (unpatched) for an x86_64 host, which runs under Rosetta,
# with new WoW64 (i386 PE code on the 64-bit host), into $INSTALL.
# The build runs natively on arm64 and cross-compiles with -arch x86_64.
# Adapted from diacunap/wine-cx-sikarugir and steamplay-mac (GPL-3.0).
#
# Usage: build-wine.sh tools          native arm64 build tools only
#        build-wine.sh [--reconfigure] the x86_64 runtime (builds tools first if needed)
set -euo pipefail
source "$(dirname "$0")/config.sh"

SRC="$SOURCES/sources/wine"
[ -f "$SRC/configure" ] || { echo "no wine sources in $SRC" >&2; exit 1; }

export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/flex/bin:$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Wine 11 needs native build tools (winebuild, winegcc, widl, wrc, makedep...) to cross compile;
# build them from the same tree for the arm64 machine first. An aarch64 build machine needs a PE
# compiler even for a tools-only tree (LLVM clang+lld), and sfnt2fon needs Homebrew's FreeType.
build_tools() {
    mkdir -p "$TOOLS"
    (cd "$TOOLS" && PKG_CONFIG_LIBDIR="" PATH="$BREW_PREFIX/opt/llvm/bin:$BREW_PREFIX/opt/lld/bin:$PATH" \
        "$SRC/configure" --enable-archs=aarch64 --with-mingw=clang --disable-tests \
        --without-x --with-freetype --without-gnutls --without-sdl --without-vulkan \
        --without-gstreamer --without-ffmpeg --without-coreaudio --without-opencl \
        CC="/usr/bin/clang" CXX="/usr/bin/clang++" CFLAGS="-O2 -g0" \
        FREETYPE_CFLAGS="-I$BREW_PREFIX/opt/freetype/include/freetype2" \
        FREETYPE_LIBS="-L$BREW_PREFIX/opt/freetype/lib -lfreetype")
    make -C "$TOOLS" -j"$JOBS" __tooldeps__
    # wrc looks for locale.nls and the codepage tables next to its own build tree.
    for f in "$SRC"/nls/*.nls; do ln -sf "$f" "$TOOLS/nls/${f##*/}"; done
}

if [ ! -x "$TOOLS/tools/winebuild/winebuild" ]; then build_tools; fi
[ "${1:-}" = tools ] && { echo "tools built in $TOOLS"; exit 0; }

export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=""
mkdir -p "$WBUILD"
cd "$WBUILD"

if [ ! -f Makefile ] || [ "${1:-}" = "--reconfigure" ]; then
    # Unix .so files live in lib/wine/x86_64-unix; @loader_path/../.. is the runtime's lib/,
    # where install-runtime.sh puts the host dylibs.
    "$SRC/configure" \
        --prefix="$INSTALL" \
        --host=x86_64-apple-darwin --build=aarch64-apple-darwin --with-wine-tools="$TOOLS" \
        --enable-archs=i386,x86_64 \
        --with-mingw \
        --disable-tests \
        --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus \
        --without-fontconfig --with-freetype --with-gnutls --without-gphoto --without-gstreamer \
        --without-krb5 --without-netapi --without-oss --without-pulse --without-sane --with-sdl \
        --without-udev --without-usb --without-v4l2 --with-vulkan --without-x --without-wayland \
        --with-ffmpeg --without-inotify --without-pcap \
        CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
        i386_CC="i686-w64-mingw32-gcc" x86_64_CC="x86_64-w64-mingw32-gcc" \
        CFLAGS="-O2 -g0" CROSSCFLAGS="-O2 -g0" \
        CPPFLAGS="-I$DEPS/include" \
        LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../.. -Wl,-headerpad_max_install_names" \
        ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib \
        PKG_CONFIG="$BREW_PREFIX/bin/pkg-config" \
        FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
        SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
        GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
        FFMPEG_CFLAGS="-I$DEPS/include" FFMPEG_LIBS="-L$DEPS/lib -lavformat -lavcodec -lavutil"
fi

# configure turns optional features off silently; fail early if one we rely on is missing.
for need in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBSDL2 SONAME_LIBVULKAN; do
    grep -q "#define $need " include/config.h || { echo "missing $need in config.h" >&2; exit 1; }
done
grep -q '#define HAVE_FFMPEG 1' include/config.h || { echo "FFmpeg not enabled" >&2; exit 1; }

make -j"$JOBS"
rm -rf "$INSTALL"
make install-lib
ln -sf ../lib/wine/x86_64-unix/wine "$INSTALL/bin/wine"

# CodeWeavers' changes must be in: these knobs only exist in the CrossOver tree.
for knob in WINE_SIMULATE_WRITECOPY CX_APPLEGPTK_LIBD3DSHARED_PATH WINEMSYNC prepend_dll_path; do
    grep -qa "$knob" "$INSTALL/lib/wine/x86_64-unix/ntdll.so" \
        || { echo "ntdll.so lacks $knob: not built from the CrossOver sources?" >&2; exit 1; }
done
echo "wine installed at $INSTALL"
