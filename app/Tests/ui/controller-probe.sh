#!/bin/zsh
# Builds the couch-mode controller probe as a small app (so macOS attributes any permission prompt to it, the
# way it would for Stepover), then opens it. Usage: app/Tests/ui/controller-probe.sh [<output folder>]
set -eu
HERE=${0:A:h}
OUT=${1:-$(mktemp -d)}
APP="$OUT/Stepover Controller Probe.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O "$HERE/controller-probe.swift" -o "$APP/Contents/MacOS/probe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.rudolphh.stepover.probe</string>
  <key>CFBundleName</key><string>Stepover Controller Probe</string>
  <key>CFBundleExecutable</key><string>probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1
echo "$APP"
