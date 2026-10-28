#!/bin/bash
# Static checks on .github/workflows/games-list.yml: it runs daily, publishes to the rolling games-list
# release without making it the repository's latest release, and pins every action by SHA.
wf=.github/workflows/games-list.yml
assert_eq "yes" "$([ -f "$wf" ] && echo yes || echo no)" "games-list workflow exists"
assert_eq "yes" "$(grep -qE '^\s*- cron: "41 10 \* \* \*"' "$wf" 2>/dev/null && echo yes || echo no)" "games-list runs daily at 10:41 UTC"
assert_eq "yes" "$(grep -q 'gh release create games-list .*--prerelease --latest=false' "$wf" 2>/dev/null && echo yes || echo no)" "the rolling release never becomes the latest release"
assert_eq "yes" "$(grep -q 'gh release upload games-list games.json --clobber' "$wf" 2>/dev/null && echo yes || echo no)" "games.json replaces the previous asset"
assert_eq "yes" "$(grep -qE "if: .*github.event_name == 'schedule'.*inputs.publish" "$wf" 2>/dev/null && echo yes || echo no)" "publishing runs on the schedule or when asked"
assert_eq "yes" "$(grep -q 'games-list verify' "$wf" 2>/dev/null && echo yes || echo no)" "the built list is verified before publishing"
unpinned=$(grep -E '^\s*(- )?uses:' "$wf" 2>/dev/null | grep -vcE '@[0-9a-f]{40}( |$)')
assert_eq "0" "${unpinned:-x}" "every action is pinned by SHA"

# The "Previous list" step, run with a fake gh: a release that doesn't exist yet is a first run; any other
# failure stops the job, since building without the previous list would publish one with no Steam facts.
step() { # step <name>: the run: script of that step
    /usr/bin/python3 -I - "$wf" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
try:
    i = next(k for k, l in enumerate(lines) if l.strip() == "- name: " + sys.argv[2])
except StopIteration:
    sys.exit("no step named " + sys.argv[2])
j = next(k for k in range(i, len(lines)) if lines[k].strip() == "run: |")
indent = len(lines[j + 1]) - len(lines[j + 1].lstrip())
for l in lines[j + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) < indent:
        break
    print(l[indent:])
PY
}
tmp=$(mktemp -d)
mkdir -p "$tmp/bin"
step "Previous list" > "$tmp/previous.sh"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$FAKE_GH:$1 $2" in
    "notfound:release view") echo "release not found" >&2; exit 1 ;;
    "down:release view"|"down:release download") echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    "ok:release view") exit 0 ;;
    "ok:release download") echo '{}' > previous.json ;;
    *) echo "unexpected: gh $*" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
previous_step() { # previous_step <fake gh mode>: prints "<exit status> <previous.json there?>"
    rm -rf "$tmp/work"; mkdir -p "$tmp/work"
    (cd "$tmp/work" && FAKE_GH=$1 GITHUB_REPOSITORY=owner/repo PATH="$tmp/bin:$PATH" bash -eo pipefail "$tmp/previous.sh" >/dev/null 2>&1)
    echo "$? $([ -f "$tmp/work/previous.json" ] && echo file || echo none)"
}
assert_eq "0 none" "$(previous_step notfound)" "no games-list release yet: a first run"
assert_eq "0 file" "$(previous_step ok)" "the previous list is downloaded"
assert_eq "yes" "$([ "$(previous_step down)" != "0 none" ] && [ "$(previous_step down | cut -d' ' -f1)" != 0 ] && echo yes || echo no)" "GitHub failing stops the job instead of building without the previous list"
rm -rf "$tmp"
