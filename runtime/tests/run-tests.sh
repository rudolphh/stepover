#!/bin/bash
# Runs every runtime/tests/test-*.sh from the repository root and exits 1 if any assertion failed.
# Test scripts call assert_eq <expected> <actual> <label>, which prints "ok <label>" or "FAIL <label>".
set -uo pipefail
cd "$(dirname "$0")/../.."

assert_eq() {
    if [ "$1" = "$2" ]; then
        echo "ok $3"
    else
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$3" "$1" "$2"
        echo x >> "$FAILURES"
    fi
}
export -f assert_eq
FAILURES="$(mktemp)"
export FAILURES

for t in runtime/tests/test-*.sh; do
    echo "== $t"
    bash "$t" || { echo "FAIL $t exited non-zero"; echo x >> "$FAILURES"; }
done

count=$(wc -l < "$FAILURES" | tr -d ' ')
rm -f "$FAILURES"
if [ "$count" -eq 0 ]; then echo "all passed"; else echo "$count failure(s)"; exit 1; fi
