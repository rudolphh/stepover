#!/bin/zsh
# Scripted check of the Library screen (Library plan B1, Task 4). Run by hand from anywhere:
#   app/Tests/ui/library-check.sh <games.json>
# Builds a test copy of Stepover (its own bundle id), runs it on scratch STEPOVER_HOMEs made of APFS clones of
# your bottles and runtimes (no extra disk; your own data is never touched), reads the window through the
# accessibility tree and prints PASS or FAIL per line. Exit 1 when anything fails.
set -u
ROOT=${0:A:h:h:h:h}
GAMES=${1:?usage: library-check.sh <games.json>}
GAMES=${GAMES:A}
REAL="$HOME/Library/Application Support/Stepover"
SCRATCH=$(mktemp -d)
APP="$SCRATCH/Stepover Test.app"
AX="$SCRATCH/axdump"
failed=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi }
quit_test() { pkill -f "Stepover Test.app/Contents/MacOS/Stepover"; sleep 1; }
launch() { # launch <home> [env...]: starts the test copy on <home>; sets $pid
    local home=$1; shift
    quit_test
    open -n --env STEPOVER_HOME="$home" --env STEPOVER_GAMES_LIST="$GAMES" "$@" "$APP"
    sleep 5
    pid=$(pgrep -f "Stepover Test.app/Contents/MacOS/Stepover" | head -1)
}
trap 'quit_test; rm -rf "$SCRATCH"' EXIT

swiftc -O "$ROOT/app/Tests/ui/axdump.swift" -o "$AX" || exit 1
STEPOVER_APP="$APP" STEPOVER_BIN=none STEPOVER_BUNDLE_ID=io.github.rudolphh.stepover.test \
    zsh "$ROOT/app/build-app.sh" >/dev/null || { echo "FAIL build"; exit 1; }

# Home A: your bottles and runtimes
home=$SCRATCH/home-a
mkdir -p "$home/Bottles" "$home/Runtimes"
find "$REAL/Bottles" "$REAL/Runtimes" -mindepth 1 -maxdepth 1 -type d | while read -r d; do
    cp -cR "$d" "$home/${${d:h}:t}/"
done
names=(${(f)"$(for c in "$home"/Bottles/*/stepover.json; do /usr/bin/python3 -I -c 'import json,sys;[print(p["name"]) for p in json.load(open(sys.argv[1])).get("programs",[])]' "$c"; done)"})
launch "$home"
dump=$("$AX" "$pid")
check "the window is the Library (no Bottles sidebar)" '! print -r -- "$dump" | grep -q "AXHeading: Bottles"'
for n in $names; do check "tile: $n" 'print -r -- "$dump" | grep -q "AXButton: $n"'; done
check "Red Dead Redemption 2 plays (tested on Mac)" 'print -r -- "$dump" | grep -E "AXButton: Red Dead Redemption 2" | grep -qE "Plays great|Runs on this Mac"'
check "Sainthood: Not tested yet" 'print -r -- "$dump" | grep -E "AXButton: Sainthood" | grep -q "Not tested yet"'
check "toolbar names the controller" 'print -r -- "$dump" | grep -qE "connected|No controller"'
"$AX" "$pid" - "Red Dead Redemption 2" >/dev/null; sleep 1
dump=$("$AX" "$pid")
check "detail panel: the full headline" 'print -r -- "$dump" | grep -qE "Plays great \(tested on Mac\)|Runs on this Mac"'
check "detail panel: a reason with its source" 'print -r -- "$dump" | grep -q "AppleGamingWiki"'
if /usr/bin/python3 -I -c 'import json,sys;g=[x for x in json.load(open(sys.argv[1]))["games"] if x.get("steam")==1174180];sys.exit(0 if g and g[0].get("store") else 1)' "$GAMES"; then
    check "detail panel: RDR2's controller answer" 'print -r -- "$dump" | grep -q "Controller works; some menus may need a mouse"'
else
    echo "SKIP RDR2's controller answer (no Steam facts for it in $GAMES yet)"
fi
"$AX" "$pid" - "Bottles" >/dev/null; sleep 1
check "View > Bottles shows the bottle pages" '"$AX" "$pid" | grep -q "AXHeading: Bottles"'
"$AX" "$pid" - "Library" >/dev/null; sleep 1

# Home B: your bottles, no runtime, a runtime list whose download can't be reached
home=$SCRATCH/home-b
mkdir -p "$home/Bottles"
find "$REAL/Bottles" -mindepth 1 -maxdepth 1 -type d | while read -r d; do cp -cR "$d" "$home/Bottles/"; done
cat > "$SCRATCH/index.json" <<'JSON'
{"runtimes":[{"name":"cx-unreachable","url":"https://127.0.0.1:9/x.tar.xz","sha256":"00","size":1000,"status":"current","minApp":"0.0.1"}]}
JSON
launch "$home" --env STEPOVER_RUNTIME_INDEX="$SCRATCH/index.json"
sleep 3
dump=$("$AX" "$pid")
check "no runtime: the games still show" 'print -r -- "$dump" | grep -q "AXButton: Sainthood"'
check "no runtime: the toolbar says the download failed" 'print -r -- "$dump" | grep -q "Couldn.t get what games need"'
check "no runtime: Retry" 'print -r -- "$dump" | grep -q "AXButton: Retry"'
"$AX" "$pid" - "Sainthood" >/dev/null; sleep 1
check "no runtime: Play waits" '"$AX" "$pid" | grep -q "AXButton: Play.*(disabled)"'
exit $failed
