#!/bin/bash
# Checks a built Stepover runtime before it goes anywhere: every part is there, Wine boots a new bottle,
# a Windows program runs, the compat plug-in loads, folder changes are reported (ReadDirectoryChangesW),
# Spatial Audio on a stereo device keeps center and sides, and with --previous a bottle made by the previous
# runtime starts on this one, and with --metal tiny Direct3D 11 and 12 programs draw through D3DMetal.
# Uses the real `stepover` command in a temporary home, so the user's bottles, logs and launchers are
# never touched. Prints "ok <check>", "skip <check> (<why>)" or "FAIL <check>: <reason>" and exits 1 at the
# first failure. The Spatial Audio check is skipped without a stereo output device (CI runners have none).
#
#   check-runtime.sh <runtime dir> [--previous <runtime dir>] [--metal]
#   STEPOVER_CLI             the stepover command (default app/.build/release/stepover)
#   STEPOVER_CHECK_TIMEOUT   seconds each Wine step may take (default 300; slow runners need more)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$(cd "${1:?usage: check-runtime.sh <runtime dir> [--previous <runtime dir>] [--metal]}" && pwd)"
shift
PREVIOUS="" METAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --previous) PREVIOUS="$(cd "$2" && pwd)"; shift 2 ;;
        --metal) METAL=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
CLI="${STEPOVER_CLI:-$ROOT/app/.build/release/stepover}"
[ -x "$CLI" ] || { echo "no stepover command at $CLI (swift build -c release --package-path app --product stepover)" >&2; exit 2; }

fail() { echo "FAIL $1: $2"; exit 1; }
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@"; }   # limit <seconds> <command...>
NAME="$(basename "$RUNTIME")"
TIMEOUT="${STEPOVER_CHECK_TIMEOUT:-300}"

for p in bin/wine bin/wineserver lib/wine/x86_64-unix/cxcompatdb.so lib/d3dmetal/external/D3DMetal.framework \
         lib/d3dmetal/wine/x86_64-windows lib/dxmt/x86_64-windows share/wine/mono share/wine/gecko; do
    [ -e "$RUNTIME/$p" ] || fail files "missing $p"
done
if grep -q '^dxvk=' "$RUNTIME/VERSION" && ! grep -q '^dxvk=none$' "$RUNTIME/VERSION"; then
    [ -e "$RUNTIME/lib/dxvk/x86_64-windows" ] || fail files "missing lib/dxvk/x86_64-windows"
fi
echo "ok files"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stepover-check.XXXX")"
export STEPOVER_HOME="$TMP/home" STEPOVER_LOGS="$TMP/logs" STEPOVER_LAUNCHERS="$TMP/launchers"
export STEPOVER_RUNTIMES="$TMP/runtimes"
unset STEPOVER_BOTTLES STEPOVER_FIXES
mkdir -p "$STEPOVER_RUNTIMES"
ln -s "$RUNTIME" "$STEPOVER_RUNTIMES/$NAME"
cleanup() {
    for b in check check-previous; do STEPOVER_RUNTIME="$NAME" "$CLI" stop "$b" >/dev/null 2>&1 || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT
x86_64-w64-mingw32-gcc -O2 -o "$TMP/hello.exe" "$ROOT/runtime/tests/hello.c"

# boot <bottle> <runtime name>: a new bottle, set up by that runtime.
boot() {
    STEPOVER_RUNTIME="$2" limit "$TIMEOUT" "$CLI" create "$1" >"$TMP/create-$1.log" 2>&1 || return 1
    cp "$TMP/hello.exe" "$STEPOVER_HOME/Bottles/$1/drive_c/hello.exe"
}
# hello <bottle> <runtime name>: runs hello.exe there and waits; with --wait, stepover run passes the
# program's output (and the plug-in's debug lines) to its caller, so it lands in $TMP/run-<bottle>.log.
hello() {
    STEPOVER_RUNTIME="$2" STEPOVER_COMPAT_DEBUG=1 limit "$TIMEOUT" "$CLI" run "$1" 'C:\hello.exe' --wait >"$TMP/run-$1.log" 2>&1
}

boot check "$NAME" || fail boot "stepover create failed or took over $TIMEOUT s: $(tail -3 "$TMP/create-check.log" | tr '\n' ' ')"
echo "ok boot"

hello check "$NAME" || fail program "hello.exe failed or took over $TIMEOUT s"
grep -q stepover-check "$TMP/run-check.log" || fail program "hello.exe printed nothing"
echo "ok program"

grep -q 'stepover-compat: hello.exe: backend' "$TMP/run-check.log" ||
    fail plugin "the compat plug-in didn't report a backend for hello.exe"
echo "ok plugin"

# run_test <name> [mingw libraries...]: builds runtime/tests/<name>.c, runs it in the check bottle and prints
# the line it reports ("<name>: ...").
run_test() {
    local name="$1"; shift
    x86_64-w64-mingw32-gcc -O2 -o "$STEPOVER_HOME/Bottles/check/drive_c/$name.exe" "$ROOT/runtime/tests/$name.c" "$@"
    STEPOVER_RUNTIME="$NAME" limit "$TIMEOUT" "$CLI" run check "C:\\$name.exe" --wait >"$TMP/run-$name.log" 2>&1 || true
    # Windows console lines end in \r\n
    grep "^$name: " "$TMP/run-$name.log" | tail -1 | tr -d '\r' | grep . ||
        echo "$name: $name.exe printed nothing (it crashed, or was still running after $TIMEOUT s); last output: $(tail -n 3 "$TMP/run-$name.log" | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
}

result="$(run_test notify)"
[ "$result" = "notify: ok" ] || fail notify "${result#notify: }"
echo "ok notify"

result="$(run_test spatial -lole32)"
case "$result" in
    "spatial: ok") echo "ok spatial" ;;
    "spatial: skip "*) echo "skip spatial ${result#spatial: skip }" ;;
    *) fail spatial "${result#spatial: }" ;;
esac

if [ -n "$PREVIOUS" ]; then
    PNAME="$(basename "$PREVIOUS")"
    [ "$PNAME" != "$NAME" ] || PNAME="$PNAME-previous"   # a rebuild of the same version
    ln -s "$PREVIOUS" "$STEPOVER_RUNTIMES/$PNAME"
    boot check-previous "$PNAME" || fail previous "creating a bottle with $PNAME failed"
    hello check-previous "$NAME" || fail previous "hello.exe failed on $NAME in a bottle made by $PNAME"
    grep -q stepover-check "$TMP/run-check-previous.log" || fail previous "hello.exe printed nothing"
    echo "ok previous"
fi

if [ "$METAL" = 1 ]; then
    # A new Wine that needs a newer D3DMetal than the one carried over shows up here, before release.
    "$CLI" graphics check '*' d3dmetal >/dev/null
    for api in d3d11 d3d12; do
        x86_64-w64-mingw32-gcc -O2 -o "$STEPOVER_HOME/Bottles/check/drive_c/$api.exe" "$ROOT/runtime/tests/$api.c" -l"$api" -ldxgi
        STEPOVER_RUNTIME="$NAME" STEPOVER_COMPAT_DEBUG=1 limit "$TIMEOUT" "$CLI" run check "C:\\$api.exe" --wait \
            >"$TMP/run-$api.log" 2>&1 || true
        grep -q "^stepover-compat: $api.exe: backend d3dmetal" "$TMP/run-$api.log" ||
            fail metal "$api.exe didn't run on D3DMetal: $(grep "^stepover-compat: $api.exe" "$TMP/run-$api.log" | tail -1)"
        if ! grep -q "^$api: ok" "$TMP/run-$api.log"; then
            reason="$(grep "^$api:" "$TMP/run-$api.log" | tail -1 || true)"   # the program's own error line
            [ -n "$reason" ] || reason="$api.exe printed nothing (it crashed, or was still running after $TIMEOUT s); last output: $(tail -n 3 "$TMP/run-$api.log" | tr '\n' ' ' | sed 's/ $//')"
            fail metal "$reason"
        fi
    done
    echo "ok metal"

    # DXMT's d3d11/dxgi import winemetal.dll, which isn't one of Wine's own DLLs: Wine loads it only through a
    # placeholder in the bottle's system32, and Wine's setup makes none (Stepover places it before a launch).
    "$CLI" graphics check '*' dxmt >/dev/null
    STEPOVER_RUNTIME="$NAME" STEPOVER_COMPAT_DEBUG=1 limit "$TIMEOUT" "$CLI" run check 'C:\d3d11.exe' --wait \
        >"$TMP/run-dxmt.log" 2>&1 || true
    grep -q "^stepover-compat: d3d11.exe: backend dxmt" "$TMP/run-dxmt.log" ||
        fail dxmt "d3d11.exe didn't run on DXMT: $(grep "^stepover-compat: d3d11.exe" "$TMP/run-dxmt.log" | tail -1)"
    if ! grep -q "^d3d11: ok" "$TMP/run-dxmt.log"; then
        reason="$(grep "^d3d11:" "$TMP/run-dxmt.log" | tail -1 | tr -d '\r' || true)"
        [ -n "$reason" ] || reason="d3d11.exe printed nothing (Wine couldn't start it, or it crashed); last output: $(tail -n 3 "$TMP/run-dxmt.log" | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
        fail dxmt "$reason"
    fi
    echo "ok dxmt"
fi
