#!/bin/zsh
# Builds Stepover.app (the bottle manager plus the `stepover` command inside it) and installs it.
#   STEPOVER_APP           where the app goes (default ~/Applications/Stepover.app)
#   STEPOVER_BIN           where the `stepover` command link goes (default ~/.local/bin; "none" to skip)
#   STEPOVER_BUNDLE_ID     default io.github.rudolphh.stepover
#   STEPOVER_VERSION       default: the VERSION file
#   STEPOVER_SOURCE_URL    shown under Help > Stepover Source Code
#   STEPOVER_SPONSOR_URL   opened by Help > Support Stepover (set it empty to leave the item out)
#   STEPOVER_RUNTIME_JSON  runtime manifest to embed (release builds; see release/make-release.sh)
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
# the fix list, used until the app downloads a newer one (FixLibrary): fix files and their licenses
rsync -a --prune-empty-dirs --include '*/' --include '*.json' --include 'LICENSE' --exclude '*' \
    "$SRC/../fixes/" "$STAGE/Contents/Resources/fixes/"

ICONSET="$SRC/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$SRC/make-icon.swift" "$ICONSET"
iconutil -c icns -o "$STAGE/Contents/Resources/AppIcon.icns" "$ICONSET"

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
  <key>StepoverSourceURL</key><string>$SOURCE_URL</string>
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
