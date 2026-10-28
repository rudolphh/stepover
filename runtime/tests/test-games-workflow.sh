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
