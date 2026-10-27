#!/bin/bash
# Downloads CodeWeavers' CrossOver source archive for $CX_VERSION, checks it against $CX_SHA256 and
# extracts it into $SOURCES (the other build scripts read $SOURCES/sources/{wine,gnutls,freetype,dxvk}).
# A marker holding the checksum skips the extraction when the same archive is already there.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ARCHIVE="crossover-sources-$CX_VERSION.tar.gz"
fetch "$CX_URL" "$CX_SHA256" "$ARCHIVE"

if [ "$(cat "$SOURCES/.extracted" 2>/dev/null)" != "$CX_SHA256" ]; then
    if [ -n "$(ls -A "$SOURCES" 2>/dev/null)" ] && [ ! -f "$SOURCES/.extracted" ]; then
        echo "$SOURCES holds sources this script didn't extract; point STEPOVER_SOURCES at an empty folder" >&2
        exit 1
    fi
    rm -rf "$SOURCES"
    mkdir -p "$SOURCES"
    tar -xzf "$DL/$ARCHIVE" -C "$SOURCES"
    echo "$CX_SHA256" > "$SOURCES/.extracted"
fi
cat "$SOURCES/sources/wine/VERSION"
