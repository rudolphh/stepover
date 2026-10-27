#!/bin/bash
# Prints the newest CrossOver source version CodeWeavers lists: X.Y.Z from crossover-sources-X.Y.Z.tar.gz
# on $CX_SOURCE_PAGE, or in a saved copy of that page given as the first argument. Names with anything
# after X.Y.Z (betas) are ignored; versions compare by number, so 26.10.0 is newer than 26.9.0.
set -euo pipefail
source "$(dirname "$0")/config.sh"

if [ $# -gt 0 ]; then page="$(cat "$1")"; else page="$(curl -fsSL --retry 3 "$CX_SOURCE_PAGE")"; fi
latest="$( { printf '%s' "$page" | grep -oE 'crossover-sources-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' || true; } \
    | sed -E 's/^crossover-sources-//; s/\.tar\.gz$//' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[ -n "$latest" ] || { echo "no CrossOver source found" >&2; exit 1; }
echo "$latest"
