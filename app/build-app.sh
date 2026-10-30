#!/bin/zsh
# Builds Stepover.app (the bottle manager plus the `stepover` command inside it) and installs it.
#   STEPOVER_APP           where the app goes (default ~/Applications/Stepover.app)
#   STEPOVER_BIN           where the `stepover` command link goes (default ~/.local/bin; "none" to skip)
#   STEPOVER_BUNDLE_ID     default io.github.rudolphh.stepover
#   STEPOVER_VERSION       default: the VERSION file
#   STEPOVER_SOURCE_URL    shown under Help > Stepover Source Code
#   STEPOVER_SPONSOR_URL   opened by Help > Support Stepover (set it empty to leave the item out)
#   STEPOVER_RUNTIME_JSON  runtime manifest to embed (release builds; see release/make-release.sh)
#   STEPOVER_GAMES_JSON    games list to embed (release builds): what the app uses until it downloads a newer one
set -eu
SRC="${0:A:h}"
APP="${STEPOVER_APP:-$HOME/Applications/Stepover.app}"
BIN="${STEPOVER_BIN:-$HOME/.local/bin}"
BUNDLE_ID="${STEPOVER_BUNDLE_ID:-io.github.rudolphh.stepover}"
VERSION="${STEPOVER_VERSION:-$(cat "$SRC/../VERSION")}"
SOURCE_URL="${STEPOVER_SOURCE_URL:-https://github.com/rudolphh/stepover}"
SPONSOR_URL="${STEPOVER_SPONSOR_URL-https://github.com/sponsors/rudolphh}"

cd "$SRC"
swift build -c release --product stepover
swift build -c release --product StepoverApp
OUT="$(swift build -c release --show-bin-path)"

STAGE="$SRC/.build/Stepover.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$OUT/StepoverApp" "$STAGE/Contents/MacOS/Stepover"
cp "$OUT/stepover" "$STAGE/Contents/MacOS/stepover-cli"   # "stepover" would collide with "Stepover"
if [ -n "${STEPOVER_RUNTIME_JSON:-}" ]; then cp "$STEPOVER_RUNTIME_JSON" "$STAGE/Contents/Resources/runtime.json"; fi
if [ -n "${STEPOVER_GAMES_JSON:-}" ]; then cp "$STEPOVER_GAMES_JSON" "$STAGE/Contents/Resources/games.json"; fi
# the fix list, used until the app downloads a newer one (FixLibrary): fix files and their licenses
rsync -a --prune-empty-dirs --include '*/' --include '*.json' --include 'LICENSE' --exclude '*' \
    "$SRC/../fixes/" "$STAGE/Contents/Resources/fixes/"

ICONSET="$SRC/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$SRC/make-icon.swift" "$ICONSET"
iconutil -c icns -o "$STAGE/Contents/Resources/AppIcon.icns" "$ICONSET"

# macOS asks for the microphone on Stepover's behalf when a game opens one (Wine's processes are Stepover's), and can
# only ask with a usage description; without it Wine waits forever for the answer (GTA V Enhanced hung on its first screen)
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Stepover</string>
  <key>CFBundleDisplayName</key><string>Stepover</string>
  <key>CFBundleExecutable</key><string>Stepover</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Games you play can use your microphone, for example for voice chat. A game works either way.</string>
  <key>StepoverSourceURL</key><string>$SOURCE_URL</string>
  <!-- a game's installer or folder dropped on the Dock icon; rank None: never the app that opens these files -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Game installer or folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string><string>com.microsoft.windows-executable</string><string>public.iso-image</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Installer package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>CFBundleTypeExtensions</key><array><string>msi</string></array>
    </dict>
  </array>
$([ -n "$SPONSOR_URL" ] && echo "  <key>StepoverSponsorURL</key><string>$SPONSOR_URL</string>")
</dict>
</plist>
EOF

codesign --force --sign - "$STAGE/Contents/MacOS/stepover-cli"
codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE"
codesign --verify --strict "$STAGE"

mkdir -p "${APP:h}"
rm -rf "$APP"
mv "$STAGE" "$APP"
if [ "$BIN" != none ]; then
    mkdir -p "$BIN"
    ln -sf "$APP/Contents/MacOS/stepover-cli" "$BIN/stepover"
    echo "installed $APP and $BIN/stepover"
else
    echo "built $APP"
fi
