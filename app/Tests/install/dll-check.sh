#!/bin/zsh
# End-to-end check that a program's or process's own WINEDLLOVERRIDES reaches Wine's DLL loader: Wine reads the
# variable before the compat plug-in can set it, so Stepover also hands the plug-in dll lines.
# Works in a scratch STEPOVER_HOME under ~/Library/Caches (removed at the end) with the installed runtimes, read only.
#   app/Tests/install/dll-check.sh        STEPOVER_CLI: the stepover command (default: this checkout's debug build)
set -u
here=$(cd "$(dirname "$0")" && pwd)
cli=${STEPOVER_CLI:-$here/../../.build/debug/stepover}
home=$HOME/Library/Caches/stepover-dll-check-$$
export STEPOVER_HOME=$home STEPOVER_LOGS=$home/logs
export STEPOVER_RUNTIMES=${STEPOVER_RUNTIMES:-$HOME/Library/Application Support/Stepover/Runtimes}
cleanup() { "$cli" stop dll >/dev/null 2>&1; rm -rf "$home"; }
trap cleanup EXIT

passed=0 total=0
check() {   # check <name> <command...>
  local name=$1; shift
  total=$((total + 1))
  if "$@"; then passed=$((passed + 1)); print "ok   $name"; else print "FAIL $name"; fi
}
loaded() {  # loaded <native|builtin>: runs dllhost.exe and compares what it reports
  local out
  out=$("$cli" run dll 'C:\game\dllhost.exe' --wait 2>&1 | tr -d '\r' | grep '^dllhost:')
  print "     | $out"
  [[ $out == "dllhost: $1" ]]
}
rule() {    # rule <json for processes>
  /usr/bin/python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["processes"]=json.loads(sys.argv[2]); json.dump(c,open(p,"w"))' \
    "$home/Bottles/dll/stepover.json" "$1"
}

"$cli" create dll >/dev/null 2>&1 || { print "FAIL create"; exit 1; }
game=$home/Bottles/dll/drive_c/game
mkdir -p "$game"
x86_64-w64-mingw32-gcc -O2 -o "$game/dllhost.exe" "$here/dllhost.c"
x86_64-w64-mingw32-gcc -O2 -shared -o "$game/dsound.dll" "$here/dllstub.c"

check "without a rule Wine uses its own dsound" loaded builtin
rule '{"dllhost.exe": {"env": {"WINEDLLOVERRIDES": "dsound=n,b"}}}'
check "a process rule's WINEDLLOVERRIDES loads the native dsound" loaded native

print "$passed/$total passed"
[[ $passed -eq $total ]]
