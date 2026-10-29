#!/bin/zsh
# Builds the test installers and folders the add-a-game checks use, into <out dir>:
#   Tiny.Game.v1.0.2-GROUP/   Inno Setup, data in setup-1.bin, a redistributable step that hangs, MD5/group-bins.md5
#   Tiny NSIS Game/           NSIS
#   Tiny GOG/                 a base Inno installer plus an add-on installer
#   Tiny Installed Game/      an installed game (no installer)
#   Empty/, Partial/ (still downloading), tiny.zip, tiny.iso (the NSIS installer on a disk image)
# Needs mingw-w64 and makensis (Homebrew), the stepover command (STEPOVER_CLI, default: this checkout's debug build)
# and an installed Wine runtime. Inno Setup's compiler is downloaded once and run under Wine in <out>/tools.
set -euo pipefail

out=${1:?usage: make-installers.sh <out dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
cli=${STEPOVER_CLI:-$here/../../.build/debug/stepover}
[[ -x $cli ]] || { echo "no stepover command at $cli (swift build --product stepover)"; exit 1; }

inno_url=https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe
inno_sha=a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c

build=$out/build
tools=$out/tools
rm -rf "$build"; mkdir -p "$build" "$tools"

# The stand-in game and the hanging redistributable.
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o "$build/TinyGame.exe" "$here/tinygame.c" -ld3d11
x86_64-w64-mingw32-gcc -O2 -o "$build/vc_redist.x64.exe" "$here/hang.c"
print "an extra file from an add-on" > "$build/Extra.txt"

# Inno Setup's compiler, in its own bottle under <out>/tools (kept between runs).
export STEPOVER_HOME=$tools/home
export STEPOVER_RUNTIMES=${STEPOVER_RUNTIMES:-$HOME/Library/Application Support/Stepover/Runtimes}
export STEPOVER_LOGS=$tools/logs
iscc='C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if [[ ! -f $STEPOVER_HOME/Bottles/iscc/drive_c/Program\ Files\ \(x86\)/Inno\ Setup\ 6/ISCC.exe ]]; then
  if [[ ! -f $tools/innosetup-6.7.4.exe ]]; then curl -fsSL -o "$tools/innosetup-6.7.4.exe" "$inno_url"; fi
  print "$inno_sha  $tools/innosetup-6.7.4.exe" | shasum -a 256 -c - >/dev/null
  [[ -d $STEPOVER_HOME/Bottles/iscc ]] || "$cli" create iscc >/dev/null
  "$cli" install iscc "$tools/innosetup-6.7.4.exe" -- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- >/dev/null
fi

winpath() { print -r -- "Z:${1//\//\\}"; }
compile() {   # compile <iss> <output folder> <base name> [defines...]
  local iss=$1 dest=$2 base=$3; shift 3
  mkdir -p "$dest"
  "$cli" wine iscc "$iscc" /Q "/DOut=$(winpath "$dest")" "/DBase=$base" "/DSrc=$(winpath "$build")" "$@" "$(winpath "$iss")"
}

game="$out/Tiny.Game.v1.0.2-GROUP"
rm -rf "$game"
compile "$here/tiny-inno.iss" "$game" setup "/DName=Tiny Game" /DExe=TinyGame.exe /DSpan=1
mkdir -p "$game/MD5"
print -r -- "$(md5 -q "$game/setup-1.bin") *..\setup-1.bin" > "$game/MD5/group-bins.md5"

nsis="$out/Tiny NSIS Game"
rm -rf "$nsis"; mkdir -p "$nsis"
makensis -V1 "-DSRC=$build" "-DOUT=$nsis/setup.exe" "$here/tiny-nsis.nsi"

gog="$out/Tiny GOG"
rm -rf "$gog"
compile "$here/tiny-inno.iss" "$gog" 'setup_tiny_gog_1.0_(64bit)_(1)' "/DName=Tiny GOG" /DExe=TinyGog.exe /DSpan=0
compile "$here/tiny-addon.iss" "$gog" 'setup_tiny_gog_-_extra_1.0_(2)'

installed="$out/Tiny Installed Game"
rm -rf "$installed"; mkdir -p "$installed"
cp "$build/TinyGame.exe" "$installed/TinyGame.exe"
cp "$build/TinyGame.exe" "$installed/UnityCrashHandler64.exe"
cp "$build/vc_redist.x64.exe" "$installed/unins000.exe"

rm -rf "$out/Empty" "$out/Partial" "$out/tiny.zip" "$out/tiny.iso"
mkdir -p "$out/Empty" "$out/Partial"
cp "$game/setup.exe" "$out/Partial/setup.exe"
head -c 4096 "$game/setup-1.bin" > "$out/Partial/setup-1.bin.part"
(cd "$out" && zip -qr tiny.zip "Tiny Installed Game")
hdiutil makehybrid -quiet -iso -joliet -o "$out/tiny.iso" "$nsis"

print "built in $out"
