# shellcheck shell=bash disable=SC2034
# Versions and paths for the Stepover Wine runtime. Sourced by every script in this directory.
# Every path can be overridden from the environment.

CX_VERSION="${STEPOVER_CX_VERSION:-26.3.0}"
CX_SHA256="${STEPOVER_CX_SHA256:-ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872}"
CX_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz"
# The page listing CodeWeavers' source archives, read by latest-crossover.sh.
CX_SOURCE_PAGE="${STEPOVER_CX_SOURCE_PAGE:-https://www.codeweavers.com/crossover/source}"

# Wine Mono / Gecko versions the CX tree expects (dlls/appwiz.cpl/addons.c; runtime/addon-versions.sh).
MONO_VERSION="${STEPOVER_MONO_VERSION:-10.4.1}"
MONO_SHA256="${STEPOVER_MONO_SHA256:-a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb}"
GECKO_VERSION="${STEPOVER_GECKO_VERSION:-2.47.4}"
GECKO_X86_SHA256="${STEPOVER_GECKO_X86_SHA256:-2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6}"
GECKO_X64_SHA256="${STEPOVER_GECKO_X64_SHA256:-fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814}"

DXMT_VERSION="${STEPOVER_DXMT_VERSION:-0.80}"

export MACOSX_DEPLOYMENT_TARGET=14.0

SRC_ROOT="${STEPOVER_SRC:-$HOME/.local/src/stepover}"
DL="${STEPOVER_DOWNLOADS:-$SRC_ROOT/downloads}"
SOURCES="${STEPOVER_SOURCES:-$SRC_ROOT/sources}" # extracted CX drop: $SOURCES/sources/{wine,gnutls,freetype}
BUILD="${STEPOVER_BUILD:-$SRC_ROOT/build}"
DEPS="$BUILD/deps"                      # x86_64 host libraries
TOOLS="$BUILD/wine-tools"               # native arm64 winebuild/widl/wrc...
WBUILD="$BUILD/wine-x86_64"
INSTALL="$BUILD/wine-install"
LOGS="$BUILD/logs"
# A rebuild of the same CrossOver version gets the next build number and its own name (cx26.3-2).
RUNTIME_BUILD="${STEPOVER_RUNTIME_BUILD:-1}"
RUNTIME_NAME="cx${CX_VERSION%.0}"
[ "$RUNTIME_BUILD" = 1 ] || RUNTIME_NAME="$RUNTIME_NAME-$RUNTIME_BUILD"
RUNTIMES="${STEPOVER_RUNTIMES:-$HOME/Library/Application Support/Stepover/Runtimes}"
GPTK_DMG="${STEPOVER_GPTK_DMG:-$HOME/Downloads/Game_Porting_Toolkit_4.0_beta_3.dmg}"
JOBS="$(sysctl -n hw.ncpu)"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

fetch() { # url sha256 out-file-name
    local url="$1" sum="$2" out="$DL/$3"
    mkdir -p "$DL"
    if [ ! -f "$out" ]; then
        curl -fSL --retry 3 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    echo "$sum  $out" | shasum -a 256 -c - >/dev/null 2>&1 || { echo "checksum mismatch: $out" >&2; rm -f "$out"; return 1; }
}
