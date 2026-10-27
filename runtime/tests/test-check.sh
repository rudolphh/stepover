#!/bin/bash
# check-runtime.sh against clones of the installed runtime: a complete one passes (also as its own
# "previous" runtime, and drawing through D3DMetal); a broken D3DMetal fails the metal check, and a
# missing one fails by name. Skipped where there's no runtime or mingw.
INSTALLED="$HOME/Library/Application Support/Stepover/Runtimes/cx26.3"
if [ ! -d "$INSTALLED" ] || ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    echo "skip test-check (no installed cx26.3 runtime or no mingw-w64)"
    exit 0
fi
if ! swift build -c release --package-path app --product stepover >/dev/null 2>&1; then
    assert_eq "0" "1" "the stepover command builds"
    exit 0
fi
BOTTLES="$HOME/Library/Application Support/Stepover/Bottles"
before="$(ls "$BOTTLES" 2>/dev/null)"

tmp=$(mktemp -d)
cp -Rc "$INSTALLED" "$tmp/cx26.3"
out="$(runtime/check-runtime.sh "$tmp/cx26.3" --previous "$tmp/cx26.3" --metal 2>&1)" && status=0 || status=$?
assert_eq "0" "$status" "complete runtime passes"
assert_eq $'ok files\nok boot\nok program\nok plugin\nok previous\nok metal' "$(printf '%s\n' "$out" | grep -E '^(ok|FAIL) ')" "every check reported"

rm "$tmp/cx26.3/lib/d3dmetal/external/D3DMetal.framework/Versions/A/D3DMetal"
out="$(runtime/check-runtime.sh "$tmp/cx26.3" --metal 2>&1)" && status=0 || status=$?
assert_eq "1" "$status" "broken D3DMetal fails"
assert_eq "FAIL metal:" "$(printf '%s\n' "$out" | grep '^FAIL' | cut -c1-11)" "caught by the metal check"

rm -rf "$tmp/cx26.3/lib/d3dmetal"
out="$(runtime/check-runtime.sh "$tmp/cx26.3" 2>&1)" && status=0 || status=$?
assert_eq "1" "$status" "runtime without D3DMetal fails"
assert_eq "FAIL files: missing lib/d3dmetal/external/D3DMetal.framework" "$(printf '%s\n' "$out" | grep '^FAIL')" "names the missing part (Review Focus 4)"

assert_eq "$before" "$(ls "$BOTTLES" 2>/dev/null)" "the user's bottles are untouched"
rm -rf "$tmp"
