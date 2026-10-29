#!/bin/zsh
# Scripted check of adding games in the app (add-a-game plan, Task 9). Run by hand from anywhere:
#   app/Tests/ui/add-check.sh <fixtures dir> [games.json]
# The fixtures come from app/Tests/install/make-installers.sh. Builds a test copy of Stepover (its own bundle id), runs
# it on a scratch STEPOVER_HOME under ~/Library/Caches (not /private: RunningPrograms.inBottle misses bottles there)
# with your installed runtimes (read only), hands it folders the way a Dock drop does (`open -a`), reads the window
# through the accessibility tree and prints PASS or FAIL per line. Exit 1 when anything fails.
set -u
ROOT=${0:A:h:h:h:h}
FIX=${1:?usage: add-check.sh <fixtures dir> [games.json]}
FIX=${FIX:A}
GAMES=${2:-}
SCRATCH=$(mktemp -d)
HOMEDIR=$HOME/Library/Caches/stepover-ui-add-$$
RUNTIMES="$HOME/Library/Application Support/Stepover/Runtimes"
APP="$SCRATCH/Stepover Add Check.app"
AX="$SCRATCH/axdump"
BUNDLE=io.github.rudolphh.stepover.addcheck
failed=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi }
quit_test() {
    pkill -f "Stepover Add Check.app/Contents/MacOS/Stepover"
    for i in {1..20}; do pgrep -qf "Stepover Add Check.app/Contents/MacOS/Stepover" || break; sleep 0.5; done
}
launch() { # starts the test copy on the scratch home and waits for its window; sets $pid
    quit_test
    local games=()
    [ -n "$GAMES" ] && games=(--env STEPOVER_GAMES_LIST="$GAMES")
    open -n --env STEPOVER_HOME="$HOMEDIR" --env STEPOVER_RUNTIMES="$RUNTIMES" --env STEPOVER_LOGS="$HOMEDIR/logs" \
        --env STEPOVER_NO_CONTROLLER=1 $games "$APP"
    for i in {1..30}; do
        pid=$(pgrep -f "Stepover Add Check.app/Contents/MacOS/Stepover" | head -1)
        [ -n "$pid" ] && "$AX" "$pid" 2>/dev/null | grep -q "== window" && break
        sleep 0.5
    done
    sleep 2
}
seen() { # seen <seconds> <pattern>: the window shows <pattern> within <seconds>
    for i in $(seq 1 $(( $1 * 2 ))); do "$AX" "$pid" 2>/dev/null | grep -qE "$2" && return 0; sleep 0.5; done
    return 1
}
stage_of() { # the stage of the queued job for <folder name>, from installs.json
    /usr/bin/python3 -I -c 'import json,sys
jobs=[j for j in json.load(open(sys.argv[1]))["jobs"] if j["source"].endswith("/"+sys.argv[2])]
print(len(jobs), *(next(iter(j["stage"])) for j in jobs))' "$HOMEDIR/installs.json" "$1" 2>/dev/null
}
done_within() { # done_within <seconds> <folder name>
    for i in $(seq 1 $1); do [[ "$(stage_of "$2")" == "1 done" ]] && return 0; sleep 1; done
    return 1
}
cleanup() {
    quit_test
    for b in "$HOMEDIR"/Bottles/*(N/); do
        STEPOVER_HOME="$HOMEDIR" STEPOVER_RUNTIMES="$RUNTIMES" "$APP/Contents/MacOS/stepover-cli" stop "${b:t}" >/dev/null 2>&1
    done
    rm -rf "$SCRATCH" "$HOMEDIR"
}
trap cleanup EXIT

swiftc -O "$ROOT/app/Tests/ui/axdump.swift" -o "$AX" || exit 1
defaults delete $BUNDLE 2>/dev/null
defaults write $BUNDLE openInCouchMode -bool false        # a connected controller would open couch mode
defaults write $BUNDLE lookUpUnknownGames -bool false     # no Steam lookups for the test games
STEPOVER_APP="$APP" STEPOVER_BIN=none STEPOVER_BUNDLE_ID=$BUNDLE zsh "$ROOT/app/build-app.sh" >/dev/null || { echo "FAIL build"; exit 1; }
mkdir -p "$HOMEDIR"

launch
check "an empty Library says to drag a game in" 'seen 5 "Drag a game.s installer or folder here"'
check "an empty Library offers Add Game from Installer or Folder" 'seen 1 "AXButton: Add Game from Installer or Folder"'

open -a "$APP" "$FIX/Tiny NSIS Game"
check "a dropped folder shows up at once, installing" 'seen 20 "Waiting to install|Getting ready|Installing"'
check "it becomes the game (installs.json: done)" 'done_within 300 "Tiny NSIS Game"'
check "and Play is there" 'seen 10 "AXButton: Play"'

open -a "$APP" "$FIX/Empty"
check "an empty folder says so" 'seen 20 "This folder doesn.t have an installer or a game in it."'
check "with Try Again" 'seen 5 "AXButton: Try Again"'
open -a "$APP" "$FIX/tiny.zip"
check "an archive says so" 'seen 20 "Unpack it first, then drag in the folder."'

open -a "$APP" "$FIX/Tiny GOG"
open -a "$APP" "$FIX/Tiny GOG"
sleep 3
check "the same folder twice is one tile" '[[ "$(stage_of "Tiny GOG")" == 1* ]]'
check "opening folders the Dock's way keeps one window" '[[ $("$AX" "$pid" | grep -c "== window") -eq 1 ]]'
check "it installs" 'seen 30 "Getting ready|Installing"'
launch   # quit mid-install (as a crash would) and open again
check "an install cut short says Interrupted" 'seen 10 "Interrupted"'
check "with Try Again" 'seen 5 "AXButton: Try Again"'

exit $failed
