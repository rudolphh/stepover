#!/bin/zsh
# End-to-end check of `stepover add` with the test installers make-installers.sh builds.
#   app/Tests/install/add-check.sh <fixtures dir>
# Works in a scratch STEPOVER_HOME under ~/Library/Caches (removed at the end) with the installed runtimes, read only.
# STEPOVER_LARGE_ADDRESS_FIX=always makes the watcher apply spec Appendix A's fix to the test installer, whose setup.tmp
# isn't large-address-aware, so the recipe runs end to end.
set -u

fixtures=${1:?usage: add-check.sh <fixtures dir>}
fixtures=$(cd "$fixtures" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
cli=${STEPOVER_CLI:-$here/../../.build/debug/stepover}
home=$HOME/Library/Caches/stepover-add-check-$$
export STEPOVER_HOME=$home STEPOVER_LOGS=$home/logs STEPOVER_LARGE_ADDRESS_FIX=always
export STEPOVER_RUNTIMES=${STEPOVER_RUNTIMES:-$HOME/Library/Application Support/Stepover/Runtimes}
bottles=$home/Bottles
mkdir -p "$home/work"

cleanup() {
  for b in "$bottles"/*(N/); do "$cli" stop "${b:t}" >/dev/null 2>&1; done
  rm -rf "$home"
}
trap cleanup EXIT

passed=0 total=0
check() {   # check <name> <command...>
  local name=$1; shift
  total=$((total + 1))
  if "$@"; then passed=$((passed + 1)); print "ok   $name"; else print "FAIL $name"; fi
}
add() {     # add <path>: runs stepover add; output in $out, exit status in $st
  out=$("$cli" add --no-lookup "$1" 2>&1); st=$?
  print -r -- "$out" | sed 's/^/     | /'
}
snapshot() { (cd "$1" && find . -type f -exec md5 -r {} + | sort) }
program_is() { grep -qF "\"exe\" : \"$2\"" "$bottles/$1/stepover.json"; }
says() { print -r -- "$out" | grep -qF -- "$1"; }
bottle_count() { print -l "$bottles"/*(N/) | wc -l | tr -d ' '; }
in_log() { grep -qF -- "$2" "$STEPOVER_LOGS/$1.log"; }
is_folder() { [[ -d $1 && ! -L $1 ]]; }
not_running() { ! "$cli" list | grep -qF "$1  [running]"; }
not_in_log() { ! in_log "$1" "$2"; }

# 1. Inno Setup, data in setup-1.bin, a redistributable step that hangs
game="$fixtures/Tiny.Game.v1.0.2-GROUP"
before=$(snapshot "$game")
add "$game"
check "Inno installer: added" test $st -eq 0
check "Inno installer: the game is TinyGame.exe" program_is "Tiny Game" 'C:\\Games\\Tiny Game\\TinyGame.exe'
check "Inno installer: the hanging step was ended" in_log "Tiny Game" "ended steps that hang under Wine: vc_redist.x64.exe"
check "Inno installer: the large-address fix ran" in_log "Tiny Game" "applied the large-address fix to setup.tmp"
check "personal folders are folders" is_folder "$bottles/Tiny Game/drive_c/users/crossover/Documents"
check "High Resolution Mode on" grep -q '"RetinaMode"="y"' "$bottles/Tiny Game/user.reg"
check "DPI 96" grep -q '"LogPixels"=dword:00000060' "$bottles/Tiny Game/user.reg"
check "outcome recorded" test -f "$bottles/Tiny Game/stepover-install.json"
check "the dropped folder is unchanged" test "$before" = "$(snapshot "$game")"
check "the shared queue has it, done" python3 -I -c 'import json,sys; j=[x for x in json.load(open(sys.argv[1]))["jobs"] if x["name"]=="Tiny Game"]; sys.exit(0 if j and "done" in j[0]["stage"] else 1)' "$home/installs.json"

# 2. NSIS
add "$fixtures/Tiny NSIS Game"
check "NSIS installer: added into C:\\Games" program_is "Tiny NSIS Game" 'C:\\Games\\Tiny NSIS Game\\TinyNsisGame.exe'

# 2b. NSIS into a folder whose name cmd would misread (& and %): the batch line escapes them
odd="$home/work/Tiny & Co 100%"
cp -Rp "$fixtures/Tiny NSIS Game" "$odd"   # -p keeps the dates: a just-copied folder waits a minute to settle
add "$odd"
check "NSIS installer: a name with & and % installs where it should" program_is "Tiny & Co 100%" 'C:\\Games\\Tiny & Co 100%\\TinyNsisGame.exe'

# 3. a base installer and an add-on, one game
add "$fixtures/Tiny GOG"
check "base + add-on: added" test $st -eq 0
check "base + add-on: the add-on's file is in the game's folder" test -f "$bottles/Tiny GOG/drive_c/Games/Tiny GOG/Extra.txt"
check "base + add-on: one bottle" test ! -d "$bottles/Tiny GOG 2"

# 4. an installed game's folder
add "$fixtures/Tiny Installed Game"
check "installed game: copied, TinyGame.exe chosen" program_is "Tiny Installed Game" 'C:\\Games\\Tiny Installed Game\\TinyGame.exe'

# 5. damaged installer files (copied just now, so it also waits for the folder to settle first)
damaged="$home/work/Damaged.Game.v1.0-GROUP"
cp -R "$game" "$damaged"
python3 -I -c 'import sys; p=sys.argv[1]; d=bytearray(open(p,"rb").read()); n=len(d)//2; d[n:n+64]=bytes(b^0xff for b in d[n:n+64]); open(p,"wb").write(d)' "$damaged/setup-1.bin"
count=$(bottle_count)
add "$damaged"
check "damaged files: says so" says "Some of the installer's files are damaged. Download them again, then Try Again."
check "damaged files: exit 1, no bottle left" test $st -eq 1 -a "$(bottle_count)" = "$count"
check "damaged files: the queue says so" python3 -I -c 'import json,sys; j=[x for x in json.load(open(sys.argv[1]))["jobs"] if x["name"]=="Damaged Game"]; sys.exit(0 if j and "damaged" in json.dumps(j[0]["stage"]) else 1)' "$home/installs.json"

# 6. nothing to install, an archive, a download in progress
add "$fixtures/Empty"
check "empty folder: says so" says "This folder doesn't have an installer or a game in it."
add "$fixtures/tiny.zip"
check "archive: says so" says "Unpack it first, then drag in the folder."
add "$fixtures/Partial"
check "still downloading: says so" says "This folder is still downloading. Try Again when it's done."
check "no bottles for those" test "$(bottle_count)" = "$count"

# 7. a disk image
add "$fixtures/tiny.iso"
check "disk image: added" program_is "tiny" 'C:\\Games\\tiny\\TinyNsisGame.exe'
check "disk image: ejected" test -z "$(hdiutil info | grep -F stepover-)"

# 8. a new bottle's first Wine session has ended once it's made: a command started while it winds down boots the bottle
#    again inside it, and each service of that second boot waits ~40 s (MountMgr, PlugPlay)
out=$("$cli" create "Fresh Bottle" 2>&1); st=$?
check "create: exit 0" test $st -eq 0
check "create returns once the new bottle's Wine has ended" not_running "Fresh Bottle"
check "create: the wait didn't run out" not_in_log "Fresh Bottle" "still running after a minute"

print "$passed/$total passed"
[[ $passed -eq $total ]]
