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
cp "$REAL/recent.json" "$REAL/learned-games.json" "$home/" 2>/dev/null   # learned: no Steam lookups, covers at once
[ -d "$REAL/Art" ] && cp -cR "$REAL/Art" "$home/"   # covers change the layout (they once pushed the row off screen)
order=(${(f)"$(/usr/bin/python3 -I -c 'import json,sys;[print(e["program"]) for e in sorted(json.load(open(sys.argv[1])), key=lambda e: -e["played"])]' "$home/recent.json" 2>/dev/null \
    | /usr/bin/python3 -I "$ROOT/app/Tests/ui/titles.py" "$GAMES" "$home/learned-games.json")"})   # as the tiles name them

quit_test
open -n --env STEPOVER_HOME="$home" --env STEPOVER_GAMES_LIST="$GAMES" --env STEPOVER_NO_CONTROLLER=1 "$APP"
for i in {1..30}; do pid=$(pgrep -f "Stepover Test.app/Contents/MacOS/Stepover" | head -1); [ -n "$pid" ] && "$AX" "$pid" 2>/dev/null | grep -q "== window" && break; sleep 0.5; done
sleep 2
osascript -e 'tell application id "io.github.rudolphh.stepover.test" to activate' 2>/dev/null
"$AX" "$pid" - "Couch Mode" >/dev/null
# going full screen takes a Space animation, during which the window reads empty
for i in {1..20}; do dump=$("$AX" "$pid"); print -r -- "$dump" | grep -q "A Play" && break; sleep 0.5; done
sleep 1; dump=$("$AX" "$pid")
check "couch mode shows the button hints" 'print -r -- "$dump" | grep -q "A Play" && print -r -- "$dump" | grep -q "X Details"'
check "the hints are on screen" '"$AX" "$pid" visible "A Play"'
check "the shortcut line is on screen" '"$AX" "$pid" visible "In a game, hold Select + Start for a second to come back here"'
check "the last played game is selected" 'print -r -- "$dump" | grep -q "AXHeading: ${order[1]}"'
"$AX" "$pid" key 124 >/dev/null; sleep 1
check "Right selects the next game" '"$AX" "$pid" | grep -q "AXHeading: ${order[2]}"'
# hiding and the way back, all from the controller (Delete = Y)
"$AX" "$pid" key 51 >/dev/null; sleep 1
check "Y asks before hiding" '"$AX" "$pid" | grep -q "Hide ${order[2]}?"'
"$AX" "$pid" key 36 >/dev/null; sleep 1
check "the hidden game leaves the row" '! "$AX" "$pid" | grep -q "AXHeading: ${order[2]}"'
"$AX" "$pid" key 48 >/dev/null; sleep 1; "$AX" "$pid" key 125 >/dev/null; sleep 0.5; "$AX" "$pid" key 36 >/dev/null; sleep 1   # Menu > Show Hidden Games
check "with hidden games shown, Y offers to put it back" '"$AX" "$pid" | grep -q "AXHeading: ${order[2]}" && "$AX" "$pid" visible "Y Show in Library"'
"$AX" "$pid" key 51 >/dev/null; sleep 1
check "Y puts it back" '"$AX" "$pid" visible "Y Hide"'
"$AX" "$pid" key 48 >/dev/null; sleep 1
check "Menu offers Leave Couch Mode" '"$AX" "$pid" | grep -q "Leave Couch Mode"'
"$AX" "$pid" key 125 >/dev/null; "$AX" "$pid" key 125 >/dev/null; sleep 1   # Down twice: Open at Login
check "Open at Login says what it does" '"$AX" "$pid" visible "Opens Stepover when you log in to this Mac, so couch mode is ready without the mouse."'
"$AX" "$pid" key 126 >/dev/null; "$AX" "$pid" key 126 >/dev/null; sleep 1   # back up to Leave Couch Mode
"$AX" "$pid" key 36 >/dev/null; sleep 2
check "Leave Couch Mode returns to the Library" '"$AX" "$pid" | grep -q "Your games"'

# Games on their way in (add-a-game plan, Task 10). A home with no runtime and a download that can't be reached, so
# a queued game stays queued; installs.json seeded with a queued and a failed game; a Downloads stand-in.
quit_test
home2=$SCRATCH/home-installs
dl=$SCRATCH/downloads
mkdir -p "$home2" "$dl/Fake Game"
printf 'MZ rDlPtS\x07' > "$dl/Fake Game/setup.exe"
touch -t 202601010000 "$dl/Fake Game/setup.exe" "$dl/Fake Game"
cat > "$SCRATCH/index.json" <<'JSON'
{"runtimes":[{"name":"cx-unreachable","url":"https://127.0.0.1:9/x.tar.xz","sha256":"00","size":1000,"status":"current","minApp":"0.0.1"}]}
JSON
/usr/bin/python3 -I - "$home2/installs.json" <<'PY'
import json, sys, time
now = time.time() - 978307200   # JSONEncoder's default dates count from 2001
job = lambda id, name, stage, added: {"id": id, "source": "/nonexistent/" + name, "name": name, "stage": stage, "added": added,
                                      "copiedGame": False, "playedSeconds": 0, "trashOffer": "pending"}
json.dump({"jobs": [job("q", "Queued Game", {"waiting": {}}, now), job("b", "Broken Game", {"failed": {"_0": {"damaged": {}}}}, now - 60)]},
          open(sys.argv[1], "w"))
PY
stage_of() { /usr/bin/python3 -I -c 'import json,sys;print(*[next(iter(j["stage"])) for j in json.load(open(sys.argv[1]))["jobs"] if j["name"]==sys.argv[2]])' "$home2/installs.json" "$1"; }
defaults write io.github.rudolphh.stepover.test lookUpUnknownGames -bool false
defaults write io.github.rudolphh.stepover.test downloadsAllowed -bool false
open -n --env STEPOVER_HOME="$home2" --env STEPOVER_GAMES_LIST="$GAMES" --env STEPOVER_NO_CONTROLLER=1 \
    --env STEPOVER_RUNTIME_INDEX="$SCRATCH/index.json" --env STEPOVER_DOWNLOADS="$dl" "$APP" --args -ApplePersistenceIgnoreState YES
for i in {1..30}; do pid=$(pgrep -f "Stepover Test.app/Contents/MacOS/Stepover" | head -1); [ -n "$pid" ] && "$AX" "$pid" 2>/dev/null | grep -q "== window" && break; sleep 0.5; done
sleep 2
osascript -e 'tell application id "io.github.rudolphh.stepover.test" to activate' 2>/dev/null
"$AX" "$pid" - "Couch Mode" >/dev/null
for i in {1..20}; do "$AX" "$pid" | grep -q "X Details" && break; sleep 0.5; done
sleep 1
check "a queued game comes first and says so" '"$AX" "$pid" | grep -q "AXHeading: Queued Game" && "$AX" "$pid" | grep -q "Waiting to install"'
"$AX" "$pid" key 124 >/dev/null; sleep 1
check "a failed install says why, with A Try Again" '"$AX" "$pid" | grep -q "Some of the installer.s files are damaged" && "$AX" "$pid" | grep -q "A Try Again"'
check "and B Remove" '"$AX" "$pid" visible "B Remove"'
"$AX" "$pid" key 36 >/dev/null; sleep 2
check "A on it queues it again" '[[ "$(stage_of "Broken Game")" == waiting ]]'
menu_last() { "$AX" "$pid" key 48 >/dev/null; sleep 1; for i in {1..8}; do "$AX" "$pid" key 125 >/dev/null; done; sleep 1; }
menu_last
check "Menu ends with Add a Game" '"$AX" "$pid" visible "Games waiting in your Downloads folder, from their installer or folder."'
"$AX" "$pid" key 36 >/dev/null; sleep 1
check "without access to Downloads it says what to do at the Mac" '"$AX" "$pid" | grep -q "Allow Stepover to see your Downloads on the Mac first"'
"$AX" "$pid" key 53 >/dev/null; sleep 1
defaults write io.github.rudolphh.stepover.test downloadsAllowed -bool true; sleep 2
menu_last
"$AX" "$pid" key 36 >/dev/null; sleep 3
check "Add a Game lists the game waiting in Downloads" '"$AX" "$pid" | grep -q "Fake Game"'
"$AX" "$pid" key 36 >/dev/null; sleep 2
check "A adds it" '[[ -n "$(stage_of "Fake Game")" ]]'
exit $failed
