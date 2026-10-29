#!/bin/zsh
# Scripted check of couch mode's screen (plan B3, Task 4). Run by hand: app/Tests/ui/couch-check.sh <games.json>
# Same harness as library-check.sh: a test copy on a scratch STEPOVER_HOME of APFS clones, read through the
# accessibility tree; the keyboard stands in for the controller (Right = 124, Tab = Menu 48, Return = A 36).
set -u
ROOT=${0:A:h:h:h:h}
GAMES=${1:?usage: couch-check.sh <games.json>}
GAMES=${GAMES:A}
REAL="$HOME/Library/Application Support/Stepover"
SCRATCH=$(mktemp -d)
APP="$SCRATCH/Stepover Test.app"
AX="$SCRATCH/axdump"
failed=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi }
quit_test() {
    pkill -f "Stepover Test.app/Contents/MacOS/Stepover"
    for i in {1..20}; do pgrep -qf "Stepover Test.app/Contents/MacOS/Stepover" || break; sleep 0.5; done
}
trap 'quit_test; rm -rf "$SCRATCH"' EXIT

swiftc -O "$ROOT/app/Tests/ui/axdump.swift" -o "$AX" || exit 1
defaults delete io.github.rudolphh.stepover.test 2>/dev/null
defaults write io.github.rudolphh.stepover.test openInCouchMode -bool false   # entered from the menu here
STEPOVER_APP="$APP" STEPOVER_BIN=none STEPOVER_BUNDLE_ID=io.github.rudolphh.stepover.test \
    zsh "$ROOT/app/build-app.sh" >/dev/null || { echo "FAIL build"; exit 1; }
home=$SCRATCH/home
mkdir -p "$home/Bottles" "$home/Runtimes"
find "$REAL/Bottles" "$REAL/Runtimes" -mindepth 1 -maxdepth 1 -type d | while read -r d; do cp -cR "$d" "$home/${${d:h}:t}/"; done
cp "$REAL/recent.json" "$home/" 2>/dev/null
order=(${(f)"$(/usr/bin/python3 -I -c 'import json,sys;[print(e["program"]) for e in sorted(json.load(open(sys.argv[1])), key=lambda e: -e["played"])]' "$home/recent.json" 2>/dev/null)"})

quit_test
open -n --env STEPOVER_HOME="$home" --env STEPOVER_GAMES_LIST="$GAMES" "$APP"
for i in {1..30}; do pid=$(pgrep -f "Stepover Test.app/Contents/MacOS/Stepover" | head -1); [ -n "$pid" ] && "$AX" "$pid" 2>/dev/null | grep -q "== window" && break; sleep 0.5; done
sleep 2
osascript -e 'tell application id "io.github.rudolphh.stepover.test" to activate' 2>/dev/null
"$AX" "$pid" - "Couch Mode" >/dev/null; sleep 3
dump=$("$AX" "$pid")
check "couch mode shows the button hints" 'print -r -- "$dump" | grep -q "A Play" && print -r -- "$dump" | grep -q "X Why"'
check "the last played game is selected" 'print -r -- "$dump" | grep -q "AXHeading: ${order[1]}"'
"$AX" "$pid" key 124 >/dev/null; sleep 1
check "Right selects the next game" '"$AX" "$pid" | grep -q "AXHeading: ${order[2]}"'
"$AX" "$pid" key 48 >/dev/null; sleep 1
check "Menu offers Leave Couch Mode" '"$AX" "$pid" | grep -q "Leave Couch Mode"'
"$AX" "$pid" key 36 >/dev/null; sleep 2
check "Leave Couch Mode returns to the Library" '"$AX" "$pid" | grep -q "Your games"'
exit $failed
