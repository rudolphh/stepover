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
quit_test() { # waits until the test copy is gone, so the next launch is a fresh process
    pkill -f "Stepover Test.app/Contents/MacOS/Stepover"
    for i in {1..20}; do pgrep -qf "Stepover Test.app/Contents/MacOS/Stepover" || break; sleep 0.5; done
}
launch() { # launch <home> [env...]: starts the test copy on <home>, waits for its window; sets $pid
    local home=$1; shift
    quit_test
    open -n --env STEPOVER_HOME="$home" --env STEPOVER_GAMES_LIST="$GAMES" --env STEPOVER_NO_CONTROLLER=1 "$@" "$APP"
    for i in {1..30}; do
        pid=$(pgrep -f "Stepover Test.app/Contents/MacOS/Stepover" | head -1)
        [ -n "$pid" ] && "$AX" "$pid" 2>/dev/null | grep -q "== window" && break
        sleep 0.5
    done
    sleep 2   # the first frame's content
}
trap 'quit_test; rm -rf "$SCRATCH"' EXIT

swiftc -O "$ROOT/app/Tests/ui/axdump.swift" -o "$AX" || exit 1
defaults delete io.github.rudolphh.stepover.test 2>/dev/null   # the test copy's own remembered view
defaults write io.github.rudolphh.stepover.test openInCouchMode -bool false   # a connected controller would open couch mode
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
# a tile goes by its game's name once matched (Steam lookups run meanwhile, so either name passes)
titles=(${(f)"$(print -rl -- $names | /usr/bin/python3 -I "$ROOT/app/Tests/ui/titles.py" "$GAMES" "$REAL/learned-games.json")"})
for i in {1..$#names}; do
    n=$names[$i] t=$titles[$i]
    check "tile: $t" 'print -r -- "$dump" | grep -qF -e "AXButton: $n" -e "AXButton: $t"'
done
check "Red Dead Redemption 2 plays (tested on Mac)" 'print -r -- "$dump" | grep -E "AXButton: Red Dead Redemption 2" | grep -qE "Plays great|Runs on this Mac"'
# installed games the list doesn't know are looked up on Steam's store in the background, one request every 1.5 s
for i in {1..20}; do grep -q '"Sainthood"' "$home/learned-games.json" 2>/dev/null && break; sleep 1; done
check "Sainthood was looked up on Steam (exact name)" '/usr/bin/python3 -I -c "import json,sys;sys.exit(0 if any(e[\"name\"]==\"Sainthood\" for e in json.load(open(sys.argv[1]))[\"entries\"]) else 1)" "$home/learned-games.json"'
dump=$("$AX" "$pid")
check "Sainthood gets an answer from Steam" 'print -r -- "$dump" | grep -E "AXButton: Sainthood" | grep -qE "Should play|Not tested yet|Probably"'
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
"$AX" "$pid" - "Settings" >/dev/null; sleep 1
dump=$("$AX" "$pid")
check "Settings opens the game's bottle page" 'print -r -- "$dump" | grep -q "AXHeading: Bottles"'
check "the bottle pages have a way back to the Library" 'print -r -- "$dump" | grep -q "AXButton: Library"'
launch "$home"
check "Settings doesn't change what the app opens on" '! "$AX" "$pid" | grep -q "AXHeading: Bottles"'

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

# Home C: a first launch: no bottles, no runtime, a download that can't be reached
home=$SCRATCH/home-c
mkdir -p "$home"
launch "$home" --env STEPOVER_RUNTIME_INDEX="$SCRATCH/index.json"
sleep 3
dump=$("$AX" "$pid")
check "first launch: an empty Library" 'print -r -- "$dump" | grep -q "No games yet"'
check "first launch: the failed download is shown" 'print -r -- "$dump" | grep -q "Couldn.t get what games need"'
check "first launch: Retry" 'print -r -- "$dump" | grep -q "AXButton: Retry"'
check "first launch: nothing that needs the runtime can start" 'print -r -- "$dump" | grep -qE "AXButton: New Bottle.*\(disabled\)"'
exit $failed
