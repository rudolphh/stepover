#!/bin/bash
# Runs single steps of .github/workflows/runtime.yml locally with fake GitHub variables: the preflight
# that stops a build early, the switch that turns the Direct3D checks off, the build number, and where the
# previous runtime comes from.
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

# Settings: a dispatch's build number names the runtime (cx26.3-2); anything but digits stops the run.
step "Settings" > "$tmp/settings.sh"
settings() { # settings <build number>: prints the STEPOVER_RUNTIME_BUILD line written to GITHUB_ENV
    : > "$tmp/env"
    CX_VERSION=26.3.0 CX_SHA256="$(printf 'a%.0s' {1..64})" BUILD_NUMBER="$1" GITHUB_ENV="$tmp/env" \
        GITHUB_WORKSPACE="$tmp" RUNNER_TEMP="$tmp" bash -eo pipefail "$tmp/settings.sh" >/dev/null 2>&1 || return 1
    grep '^STEPOVER_RUNTIME_BUILD=' "$tmp/env"
}
assert_eq "STEPOVER_RUNTIME_BUILD=2" "$(settings 2)" "a dispatch's build number reaches the build"
assert_eq "STEPOVER_RUNTIME_BUILD=1" "$(settings "")" "no build number is build 1"
settings '2; true' >/dev/null && status=0 || status=$?
assert_eq "1" "$status" "a build number that isn't digits stops the run"
settings 0 >/dev/null && status=0 || status=$?
assert_eq "1" "$status" "build numbers start at 1"
settings 02 >/dev/null && status=0 || status=$?
assert_eq "1" "$status" "a build number has no leading zero"

# Current published runtime: D3DMetal and the previous runtime come from runtime/index.json's current
# entry (app releases no longer carry a runtime), checked against the sha256 the list records.
step "Current published runtime (D3DMetal, and the previous runtime for the checks)" > "$tmp/previous.sh"
mkdir -p "$tmp/rt/cx9.9/lib/d3dmetal" "$tmp/ws/runtime" "$tmp/pub"
echo d3dmetal > "$tmp/rt/cx9.9/lib/d3dmetal/marker"
tar -cJf "$tmp/pub/stepover-runtime-cx9.9.tar.xz" -C "$tmp/rt" cx9.9
good="$(shasum -a 256 "$tmp/pub/stepover-runtime-cx9.9.tar.xz" | cut -d' ' -f1)"
index() { # index <sha256>: an older runtime, an earlier current one, the last current one (no status
    # counts as current, as in the app), then a pulled one
    cat > "$tmp/ws/runtime/index.json" <<JSON
{"runtimes": [
  {"name": "cx9.7", "url": "file://$tmp/pub/missing.tar.xz", "sha256": "$(printf 'b%.0s' {1..64})", "status": "available"},
  {"name": "cx9.8", "url": "file://$tmp/pub/missing.tar.xz", "sha256": "$(printf 'd%.0s' {1..64})", "status": "current"},
  {"name": "cx9.9", "url": "file://$tmp/pub/stepover-runtime-cx9.9.tar.xz", "sha256": "$1"},
  {"name": "cx9.9-2", "url": "file://$tmp/pub/missing.tar.xz", "sha256": "$(printf 'c%.0s' {1..64})", "status": "pulled"}
]}
JSON
}
previous() {
    rm -rf "$tmp/runner"; mkdir -p "$tmp/runner"; : > "$tmp/env"
    GITHUB_WORKSPACE="$tmp/ws" RUNNER_TEMP="$tmp/runner" GITHUB_ENV="$tmp/env" bash -eo pipefail "$tmp/previous.sh" >/dev/null 2>&1
}
index "$good"
previous && status=0 || status=$?
assert_eq "0" "$status" "the current runtime in the list downloads and checks out"
assert_eq "STEPOVER_D3DMETAL_ARCHIVE=$tmp/runner/previous/stepover-runtime-cx9.9.tar.xz
PREVIOUS_RUNTIME=$tmp/runner/previous/cx9.9" "$(cat "$tmp/env")" "D3DMetal and the previous runtime come from the current entry"
assert_eq "d3dmetal" "$(cat "$tmp/runner/previous/cx9.9/lib/d3dmetal/marker" 2>/dev/null)" "the previous runtime is unpacked"
index "$(printf '0%.0s' {1..64})"
previous && status=0 || status=$?
assert_eq "1" "$status" "a download that doesn't match the list's sha256 stops the run"
rm -rf "$tmp"
