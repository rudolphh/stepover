#!/bin/zsh
# Publishes release/dist/<version>/ (from make-release.sh) to GitHub:
#   1. the source repository STEPOVER_GITHUB_REPO (default rudolphh/stepover), public, created if missing
#   2. a GitHub release v<version> with the app, the sources and SHA256SUMS (runtimes ship on their own)
#   3. the tap repository STEPOVER_TAP_REPO (default <owner>/homebrew-stepover) with Casks/stepover.rb
# Everything it publishes is public. Needs `gh auth login`.
set -eu
ROOT="${0:A:h:h}"
VERSION="$(cat "$ROOT/VERSION")"
REPO="${STEPOVER_GITHUB_REPO:-rudolphh/stepover}"
TAP_REPO="${STEPOVER_TAP_REPO:-${REPO%%/*}/homebrew-stepover}"
DIST="$ROOT/release/dist/$VERSION"

[ -f "$DIST/tap/Casks/stepover.rb" ] || { echo "run release/make-release.sh first" >&2; exit 1; }
grep -q "github.com/$REPO/" "$DIST/runtime.json" || { echo "release was built for another repository" >&2; exit 1; }
gh auth status >/dev/null

echo "== source repository $REPO"
cd "$ROOT"
[ -d .git ] || git init -b main
git add -A
git diff --cached --quiet || git commit -q -m "Stepover $VERSION"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" --public --description "Run Windows games on Apple Silicon with Wine built from CrossOver's source, D3DMetal, DXMT and DXVK" \
        --source "$ROOT" --remote origin --push
else
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
    git push -u origin main
fi

echo "== release v$VERSION"
if ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "v$VERSION" --repo "$REPO" --title "Stepover $VERSION" --notes-file - \
        "$DIST"/Stepover-*.zip "$DIST"/stepover-runtime-*.tar.xz(N) "$DIST"/SHA256SUMS "$DIST"/sources/*(N) <<EOF
Install: \`brew trust --tap ${TAP_REPO%%/*}/stepover && brew install --cask ${TAP_REPO%%/*}/stepover/stepover\`

The app downloads its Wine runtime ($(awk -F'"' '/"summary"/{print $4}' "$DIST/runtime.json")) on first launch, from Stepover's runtime list (runtime/index.json); new runtimes appear in the app as they're published.

The \`sources/\` files are the exact archives this release was built from (CodeWeavers' CrossOver
26.3 source, nettle, SDL, FFmpeg) and Stepover's own source. Not affiliated with CodeWeavers or
Apple; Apple's D3DMetal is included for non-commercial use on Apple hardware only.
EOF
fi

echo "== tap $TAP_REPO"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    gh repo clone "$TAP_REPO" "$TMP/tap" -- -q
else
    mkdir -p "$TMP/tap" && git -C "$TMP/tap" init -q -b main
fi
mkdir -p "$TMP/tap/Casks"
cp "$DIST/tap/Casks/stepover.rb" "$TMP/tap/Casks/stepover.rb"
cat > "$TMP/tap/README.md" <<EOF
# Homebrew tap for Stepover

    brew trust --tap ${TAP_REPO%%/*}/stepover
    brew install --cask ${TAP_REPO%%/*}/stepover/stepover

Stepover: https://github.com/$REPO
EOF
git -C "$TMP/tap" add -A
git -C "$TMP/tap" diff --cached --quiet || git -C "$TMP/tap" commit -q -m "stepover $VERSION"
if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    git -C "$TMP/tap" push -q origin main
else
    gh repo create "$TAP_REPO" --public --description "Homebrew tap for Stepover" --source "$TMP/tap" --remote origin --push
fi
echo "published Stepover $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
