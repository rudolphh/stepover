#!/bin/zsh
# Scripted check that stopping a bottle ends every program in it, even one that can't answer Wine's request to
# end (a hung game; here a paused Notepad). Run by hand: app/Tests/ui/stop-check.sh [bottle name]
# A scratch STEPOVER_HOME of APFS clones of one of your bottles and your runtimes, driven by the CLI from this tree.
set -u
ROOT=${0:A:h:h:h:h}
REAL="$HOME/Library/Application Support/Stepover"
NAME=${1:-$(ls "$REAL/Bottles" | head -1)}
# not under /private (mktemp's /var/folders is /private/var/folders): RunningPrograms.inBottle compares
# resolvingSymlinksInPath, which drops /private, with working directories that keep it
SCRATCH=$(mktemp -d "$HOME/Library/Caches/stepover-stop-check.XXXXXX")
home=$SCRATCH/home
failed=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi }
in_bottle() {
    for p in $(pgrep -f 'C:\\|\.exe'); do
        c=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)
        case "$c" in "$home/Bottles/StopCheck"*) echo $p;; esac
    done
}
trap 'left=$(in_bottle); [ -n "$left" ] && kill -KILL ${=left}; rm -rf "$SCRATCH"; rm -f "$HOME/Library/Logs/Stepover/StopCheck.log"' EXIT

mkdir -p "$home/Bottles" "$home/Runtimes"
cp -cR "$REAL/Bottles/$NAME" "$home/Bottles/StopCheck"
find "$REAL/Runtimes" -mindepth 1 -maxdepth 1 -type d -exec cp -cR {} "$home/Runtimes/" \;
(cd "$ROOT/app" && swift build --product stepover >/dev/null 2>&1) || { echo "FAIL build"; exit 1; }
CLI="$ROOT/app/.build/debug/stepover"

started=$(STEPOVER_HOME="$home" "$CLI" run StopCheck 'C:\windows\notepad.exe')
pid=${${started##*\(pid }%%\)*}
sleep 6   # Wine's own services come up
kill -STOP $pid   # can't answer the server now, as a hung game can't
# a program in the bottle the server has lost (what two frozen games left behind: alive, no server to end them)
(cd "$home/Bottles/StopCheck/drive_c" && exec -a 'C:\windows\lost.exe' /bin/sleep 300) &
sleep 1
check "Notepad, Wine's services and the lost program are running" '[ $(in_bottle | wc -l) -ge 4 ]'
begin=$SECONDS
STEPOVER_HOME="$home" "$CLI" stop StopCheck
took=$((SECONDS - begin)); sleep 1
left=$(in_bottle)
check "stop ends every program in the bottle (left: ${left//$'\n'/ })" '[ -z "$left" ]'
check "stop takes under 5 s (took ${took} s)" '[ $took -lt 5 ]'
exit $failed
