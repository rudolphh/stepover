#!/bin/bash
# runtime/config.sh: version overrides, runtime names with build numbers, and fetch's checksum guard.

assert_eq "cx26.3"   "$(STEPOVER_CX_VERSION=26.3.0 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "build 1 name"
assert_eq "cx26.3-2" "$(STEPOVER_CX_VERSION=26.3.0 STEPOVER_RUNTIME_BUILD=2 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "build 2 name"
assert_eq "cx26.4.1" "$(STEPOVER_CX_VERSION=26.4.1 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "patch version name"
assert_eq "26.3.0"   "$(bash -c 'source runtime/config.sh; echo $CX_VERSION')" "default version unchanged"
assert_eq "/x/src"   "$(STEPOVER_SOURCES=/x/src bash -c 'source runtime/config.sh; echo $SOURCES')" "sources override"

# Review Focus 2: an archive that changed under a pinned checksum is refused and removed.
tmp=$(mktemp -d)
echo changed > "$tmp/crossover-sources-26.3.0.tar.gz"
STEPOVER_DOWNLOADS="$tmp" bash -c 'source runtime/config.sh; fetch "file:///dev/null" "$CX_SHA256" crossover-sources-26.3.0.tar.gz' \
    2>"$tmp/err" && status=0 || status=$?
assert_eq "1" "$status" "changed archive refused"
assert_eq "checksum mismatch: $tmp/crossover-sources-26.3.0.tar.gz" "$(cat "$tmp/err")" "mismatch message"
assert_eq "no" "$([ -f "$tmp/crossover-sources-26.3.0.tar.gz" ] && echo yes || echo no)" "bad archive removed"
rm -rf "$tmp"

# fetch-sources.sh never replaces a sources folder it didn't extract (for example the main checkout's).
tmp=$(mktemp -d)
mkdir -p "$tmp/sources/keep" && echo mine > "$tmp/sources/keep/file"
STEPOVER_SOURCES="$tmp/sources" runtime/fetch-sources.sh >/dev/null 2>"$tmp/err" && status=0 || status=$?
assert_eq "1" "$status" "foreign sources folder refused"
assert_eq "mine" "$(cat "$tmp/sources/keep/file" 2>/dev/null)" "foreign sources folder untouched"
assert_eq "$tmp/sources holds sources this script didn't extract; point STEPOVER_SOURCES at an empty folder" "$(cat "$tmp/err")" "refusal message"
rm -rf "$tmp"
