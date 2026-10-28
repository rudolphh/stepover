#!/bin/zsh
# Builds everything a Stepover release needs into release/dist/<version>/, without publishing:
#   Stepover-<version>.zip              the app, with the runtime list's current runtime embedded as
#                                       runtime.json (what a first launch downloads when it can't reach the list)
#   sources/                          the source archives the LGPL obligations call for
#   tap/Casks/stepover.rb               the Homebrew cask for the tap repository
#   SHA256SUMS
# Runtimes ship on their own (runtime/index.json); an app release no longer carries one.
# Config (env): STEPOVER_GITHUB_REPO (owner/name, default rudolphh/stepover), STEPOVER_BUNDLE_ID,
# STEPOVER_DOWNLOADS (the source archives, default <repo>/downloads).
set -eu
ROOT="${0:A:h:h}"
VERSION="$(cat "$ROOT/VERSION")"
REPO="${STEPOVER_GITHUB_REPO:-rudolphh/stepover}"
OWNER="${REPO%%/*}"
BUNDLE_ID="${STEPOVER_BUNDLE_ID:-io.github.$OWNER.stepover}"
DL="${STEPOVER_DOWNLOADS:-$ROOT/downloads}"
OUT="$ROOT/release/dist/$VERSION"

rm -rf "$OUT"
mkdir -p "$OUT/sources" "$OUT/tap/Casks"

echo "== runtime.json (the runtime list's current runtime)"
/usr/bin/python3 -I - "$ROOT/runtime/index.json" "$OUT/runtime.json" <<'PY'
import json, sys
current = [r for r in json.load(open(sys.argv[1])).get("runtimes", []) if r.get("status", "current") == "current"]
if not current:
    sys.exit("runtime/index.json has no current runtime")
json.dump(current[-1], open(sys.argv[2], "w"), indent=2)
PY
RT_SIZE="$(/usr/bin/python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["size"])' "$OUT/runtime.json")"

echo "== app"
STEPOVER_APP="$OUT/Stepover.app" STEPOVER_BIN=none STEPOVER_BUNDLE_ID="$BUNDLE_ID" STEPOVER_VERSION="$VERSION" \
    STEPOVER_SOURCE_URL="https://github.com/$REPO" STEPOVER_SPONSOR_URL="https://github.com/sponsors/$OWNER" \
    STEPOVER_RUNTIME_JSON="$OUT/runtime.json" \
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
    --exclude "${ROOT:t}/downloads" --exclude "${ROOT:t}/sources" --exclude "${ROOT:t}/build" \
    --exclude "${ROOT:t}/app/.build" --exclude "${ROOT:t}/release/dist" --exclude "${ROOT:t}/.git" \
    --exclude "${ROOT:t}/.worktrees" --exclude "${ROOT:t}/.superpowers" --exclude '.DS_Store' "${ROOT:t}"

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

(cd "$OUT" && shasum -a 256 "$APP_FILE" sources/* > SHA256SUMS)
echo "release $VERSION in $OUT"
ls -la "$OUT" "$OUT/sources"
