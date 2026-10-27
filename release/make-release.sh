#!/bin/zsh
# Builds everything a Stepover release needs into release/dist/<version>/, without publishing:
#   stepover-runtime-<runtime>.tar.xz   the Wine runtime the app downloads on first launch
#   Stepover-<version>.zip              the app (runtime manifest embedded)
#   sources/                          the source archives the LGPL obligations call for
#   tap/Casks/stepover.rb               the Homebrew cask for the tap repository
#   SHA256SUMS
# Config (env): STEPOVER_GITHUB_REPO (owner/name, default rudolphh/stepover), STEPOVER_BUNDLE_ID,
# STEPOVER_RUNTIMES, STEPOVER_RUNTIME (default cx26.3).
set -eu
ROOT="${0:A:h:h}"
VERSION="$(cat "$ROOT/VERSION")"
REPO="${STEPOVER_GITHUB_REPO:-rudolphh/stepover}"
OWNER="${REPO%%/*}"
BUNDLE_ID="${STEPOVER_BUNDLE_ID:-io.github.$OWNER.stepover}"
RUNTIMES="${STEPOVER_RUNTIMES:-$HOME/Library/Application Support/Stepover/Runtimes}"
RUNTIME="${STEPOVER_RUNTIME:-cx26.3}"
DL="$ROOT/downloads"
OUT="$ROOT/release/dist/$VERSION"
BASE_URL="https://github.com/$REPO/releases/download/v$VERSION"

[ -x "$RUNTIMES/$RUNTIME/bin/wine" ] || { echo "no runtime at $RUNTIMES/$RUNTIME" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/sources" "$OUT/tap/Casks"

echo "== runtime archive"
RT_FILE="stepover-runtime-$RUNTIME.tar.xz"
COPYFILE_DISABLE=1 tar -c -C "$RUNTIMES" --exclude '.DS_Store' --exclude '.stepover-manifest.json' \
    "$RUNTIME" | xz -T0 -6 > "$OUT/$RT_FILE"
RT_SHA="$(shasum -a 256 "$OUT/$RT_FILE" | cut -d' ' -f1)"
RT_SIZE="$(stat -f %z "$OUT/$RT_FILE")"
RT_SUMMARY="$(awk -F= '/^wine=/{w=$2} /^d3dmetal=/{d=$2} /^dxmt=/{x=$2} /^dxvk=/{v=$2} END{print w ", D3DMetal " d ", DXMT " x ", DXVK " v}' "$RUNTIMES/$RUNTIME/VERSION")"
cat > "$OUT/runtime.json" <<EOF
{
  "name": "$RUNTIME",
  "url": "$BASE_URL/$RT_FILE",
  "sha256": "$RT_SHA",
  "size": $RT_SIZE,
  "summary": "$RT_SUMMARY"
}
EOF

echo "== app"
STEPOVER_APP="$OUT/Stepover.app" STEPOVER_BIN=none STEPOVER_BUNDLE_ID="$BUNDLE_ID" STEPOVER_VERSION="$VERSION" \
    STEPOVER_SOURCE_URL="https://github.com/$REPO" STEPOVER_RUNTIME_JSON="$OUT/runtime.json" \
    "$ROOT/app/build-app.sh"
APP_FILE="Stepover-$VERSION.zip"
(cd "$OUT" && ditto -c -k --norsrc --noextattr --noacl --keepParent Stepover.app "$APP_FILE")
rm -rf "$OUT/Stepover.app"
APP_SHA="$(shasum -a 256 "$OUT/$APP_FILE" | cut -d' ' -f1)"

echo "== sources"
for f in crossover-sources-26.3.0.tar.gz nettle-3.10.2.tar.gz SDL2-2.32.10.tar.gz ffmpeg-7.1.5.tar.xz; do
    cp -c "$DL/$f" "$OUT/sources/$f"
done
COPYFILE_DISABLE=1 tar -czf "$OUT/sources/stepover-$VERSION-source.tar.gz" -C "${ROOT:h}" \
    --exclude 'stepover/downloads' --exclude 'stepover/sources' --exclude 'stepover/build' \
    --exclude 'stepover/app/.build' --exclude 'stepover/release/dist' --exclude 'stepover/.git' \
    --exclude 'stepover/.worktrees' --exclude '.DS_Store' "${ROOT:t}"

echo "== cask"
cat > "$OUT/tap/Casks/stepover.rb" <<EOF
cask "stepover" do
  version "$VERSION"
  sha256 "$APP_SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Stepover-#{version}.zip"
  name "Stepover"
  desc "Run Windows games with Wine built from CrossOver's source, D3DMetal, DXMT and DXVK"
  homepage "https://github.com/$REPO"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on formula: "winetricks"

  app "Stepover.app"
  binary "#{appdir}/Stepover.app/Contents/MacOS/stepover-cli", target: "stepover"

  # Signed for this Mac only (no Apple Developer ID), like Sikarugir: clear the download flag
  # and sign locally so Gatekeeper lets it open.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-drs", "com.apple.quarantine", "{{appdir}}/Stepover.app"]
    run "/usr/bin/codesign", args: ["--force", "--deep", "-s", "-", "{{appdir}}/Stepover.app"]
  end

  zap trash: [
    "~/Library/Application Support/Stepover",
    "~/Library/Logs/Stepover",
  ]

  caveats do
    requires_rosetta
    <<~EOS
      Stepover downloads its Wine runtime ($(( RT_SIZE / 1000000 )) MB) the first time it opens.
      Not affiliated with CodeWeavers or Apple. Apple's D3DMetal is included for
      non-commercial use on Apple hardware only.
    EOS
  end
end
EOF

(cd "$OUT" && shasum -a 256 "$RT_FILE" "$APP_FILE" sources/* > SHA256SUMS)
echo "release $VERSION in $OUT"
ls -la "$OUT" "$OUT/sources"
