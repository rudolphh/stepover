#!/bin/bash
# Runs single steps of .github/workflows/runtime.yml locally with fake GitHub variables: the preflight
# that stops a build early, and the switch that turns the Direct3D checks off.
step() { # step <name>: the run: script of that step
    /usr/bin/python3 -I - .github/workflows/runtime.yml "$1" <<'PY'
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
step "Preflight (Rosetta and free disk)" > "$tmp/preflight.sh"
step "Metal" > "$tmp/metal.sh"

out="$(MIN_DISK_GB=999999 bash -eo pipefail "$tmp/preflight.sh" 2>&1)" && status=0 || status=$?
assert_eq "1" "$status" "preflight stops a build without enough disk"
assert_eq "yes" "$(printf '%s' "$out" | grep -qE '^only [0-9]+ GB free; the build needs 999999 GB$' && echo yes || echo no)" "preflight says why"
MIN_DISK_GB=1 bash -eo pipefail "$tmp/preflight.sh" >/dev/null 2>&1 && status=0 || status=$?
assert_eq "0" "$status" "preflight passes with enough disk and Rosetta"

: > "$tmp/env"
CI_METAL=false GITHUB_ENV="$tmp/env" bash -eo pipefail "$tmp/metal.sh"
assert_eq "CHECK_METAL=skip metal: turned off by the STEPOVER_CI_METAL repository variable" "$(cat "$tmp/env")" "Metal checks can be turned off"
: > "$tmp/env"
CI_METAL="" GITHUB_ENV="$tmp/env" bash -eo pipefail "$tmp/metal.sh"
assert_eq "CHECK_METAL=yes" "$(cat "$tmp/env")" "Metal checks run where Metal works"
rm -rf "$tmp"
