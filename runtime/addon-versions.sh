#!/bin/bash
# Prints the Wine Mono and Gecko versions a Wine source tree expects, as MONO_VERSION=<v> and
# GECKO_VERSION=<v> lines, from <wine source dir>/dlls/appwiz.cpl/addons.c.
set -euo pipefail

file="${1:?usage: addon-versions.sh <wine source dir>}/dlls/appwiz.cpl/addons.c"
define() { { sed -nE "s/^#define $1 \"([^\"]+)\".*/\\1/p" "$file" 2>/dev/null || true; } | head -1; }
mono="$(define MONO_VERSION)"
gecko="$(define GECKO_VERSION)"
[ -n "$mono" ] && [ -n "$gecko" ] || { echo "no Mono or Gecko version in $file" >&2; exit 1; }
echo "MONO_VERSION=$mono"
echo "GECKO_VERSION=$gecko"
