# Runtime Build Pipeline Implementation Plan (plan 1 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daily GitHub job that notices new CrossOver source, builds a Stepover runtime from it on a GitHub macOS runner, runs the automated checks, and keeps the result as a workflow artifact. It publishes nothing.

**Architecture:** The existing `runtime/*.sh` build scripts run unchanged in CI, driven by environment overrides added to `runtime/config.sh`. New scripts fetch the source, detect new versions, take D3DMetal from a published runtime, and check a built runtime through the real `stepover` command. One workflow (`runtime.yml`) ties them together; a separate spike workflow measures the runner first.

**Tech Stack:** bash, GitHub Actions (`macos-15`, Apple Silicon), Homebrew build tools, mingw-w64 for the Windows test programs, Swift 5.10 (`app/`).

**Spec:** `docs/superpowers/specs/2026-10-27-automatic-runtime-builds-design.md` (sections 1, 2, 3; the roadmap is `docs/superpowers/plans/2026-10-27-runtime-builds-roadmap.md`)

## Global Constraints

- Work on a new branch from the current `main` (0.2.2 or later) in a worktree under `.worktrees/`; `main` has 32 app tests.

- Runner `macos-15` (Apple Silicon), as `.github/workflows/fixes.yml` uses.
- `MACOSX_DEPLOYMENT_TARGET=14.0` (from `runtime/config.sh`).
- Actions pinned by full commit SHA: `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`, `actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`.
- Workflow `permissions: contents: read`. No secrets beyond the default `GITHUB_TOKEN`.
- This plan publishes nothing: no releases, no commits or pushes from CI, workflow artifacts only.
- Every version and path comes from a `STEPOVER_*` environment variable, with today's value as the default. Nothing is hardcoded.
- Runtime names: `cx<CX_VERSION without a trailing .0>` for build 1, `cx<...>-<N>` for build N of 2 or more (spec section 2).
- "A changed archive under the same name is never treated as a new release" (spec section 1).
- Shell scripts follow `runtime/*.sh`: `#!/bin/bash`, `set -euo pipefail`, `source "$(dirname "$0")/config.sh"`, a header comment saying what the script does.
- No em dashes in prose, comments or UI copy.
- Pushing a branch to `rudolphh/stepover` or running a workflow there needs the maintainer's OK at that moment.

## Review Focus

1. CodeWeavers' page lists `26.10.0` next to `26.9.0`, or a beta like `26.4.0-beta1`: the newest stable version by number wins (`26.10.0`), betas are ignored. Test in Task 5.
2. The pinned archive changes under the same version: the job fails with `checksum mismatch` and builds nothing. Test in Task 2.
3. The published runtime used for D3DMetal is missing or corrupt: `install-runtime.sh` fails instead of producing a runtime without D3DMetal. Test in Task 4.
4. A runtime missing a required part (D3DMetal, the compat plug-in, DXMT) fails check (a) by name. Test in Task 6.
5. A new source drop names Mono or Gecko versions that differ from `config.sh`: the workflow uses the source's versions, and a failed download fails the job. Parsing tested in Task 5; the failure path is `fetch`'s `curl -f`, exercised in Task 8's dry run.

---

### Task 1: Build-machine spike

**Files:**
- Create: `.github/workflows/runtime-spike.yml`
- Create: `runtime/tests/metal-probe.swift`
- Create: `docs/runtime-ci-spike.md`

**Interfaces:**
- Produces: `docs/runtime-ci-spike.md` with lines `rosetta=yes|no`, `metal=<device name>|none`, `free_disk_gb=<n>`, `cores=<n>`, `memory_gb=<n>`, `brew_minutes=<n>`. Task 7 and Task 8 read `metal=`.

- [ ] **Step 1: Write `runtime/tests/metal-probe.swift`**

Prints `metal=<MTLDevice.name>` and `metal-queue=ok` when `MTLCreateSystemDefaultDevice()` returns a device that can make a command queue, otherwise `metal=none`. Exit 0 either way.

- [ ] **Step 2: Run it locally**

Run: `swift runtime/tests/metal-probe.swift`
Expected: `metal=Apple M4 Max` and `metal-queue=ok` on the maintainer's Mac.

- [ ] **Step 3: Write `.github/workflows/runtime-spike.yml`**

Triggers: `push` to branches `runtime-ci/**` (paths: this file and `runtime/tests/metal-probe.swift`) and `workflow_dispatch`. One job on `macos-15`. Steps, each appending to `$GITHUB_STEP_SUMMARY`: machine (`uname -m`, `sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize`, `sw_vers`, `xcodebuild -version`, `df -g /`); Rosetta (`arch -x86_64 /usr/bin/true`; if it fails, `softwareupdate --install-rosetta --agree-to-license` and retry; print `rosetta=yes|no`); Metal (`swift runtime/tests/metal-probe.swift`); Homebrew (time `brew install mingw-w64 bison flex ninja cmake pkgconf autoconf automake libtool llvm lld nasm meson glslang freetype`, print `brew_minutes=`).

- [ ] **Step 4: Run it on GitHub (maintainer's OK first)**

Run: `git push origin HEAD:runtime-ci/pipeline` then `gh run watch --repo rudolphh/stepover $(gh run list --repo rudolphh/stepover --workflow runtime-spike.yml --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: the run succeeds and its summary shows all six values.

- [ ] **Step 5: Record the results and apply the gate**

Write the six values to `docs/runtime-ci-spike.md`. Gate: if `rosetta=no` or `free_disk_gb` is under 15 (the local build uses about 3 GB of build, source and download folders, plus Homebrew), stop and report to the maintainer; the spec's fallback is a self-hosted runner. If `metal=none`, mark Task 7 as skipped in the same file.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/runtime-spike.yml runtime/tests/metal-probe.swift docs/runtime-ci-spike.md
git commit -m "runtime CI: measure the GitHub macOS runner"
```

### Task 2: Overridable versions, runtime build numbers and fetching the source

**Files:**
- Modify: `runtime/config.sh:5-31`
- Modify: `runtime/install-runtime.sh` (the `VERSION` heredoc)
- Create: `runtime/fetch-sources.sh`
- Create: `runtime/tests/run-tests.sh`, `runtime/tests/test-config.sh`

**Interfaces:**
- Produces: in `config.sh`, `CX_VERSION="${STEPOVER_CX_VERSION:-26.3.0}"`, `CX_SHA256="${STEPOVER_CX_SHA256:-ac99c8ca…6872}"` (the current full value), the same pattern for `MONO_VERSION`, `MONO_SHA256`, `GECKO_VERSION`, `GECKO_X86_SHA256`, `GECKO_X64_SHA256`, `DXMT_VERSION`; `SOURCES="${STEPOVER_SOURCES:-$SRC_ROOT/sources}"`; `RUNTIME_BUILD="${STEPOVER_RUNTIME_BUILD:-1}"`; `RUNTIME_NAME` = `cx${CX_VERSION%.0}` when `RUNTIME_BUILD` is 1, else `cx${CX_VERSION%.0}-$RUNTIME_BUILD`.
- Produces: `runtime/fetch-sources.sh` (no arguments): fetches `crossover-sources-$CX_VERSION.tar.gz` with `fetch` (checksum `CX_SHA256`) and extracts it into `$SOURCES` unless `$SOURCES/.extracted` already holds `$CX_SHA256`; writes that marker; prints `$SOURCES/sources/wine/VERSION`.
- Produces: `runtime/tests/run-tests.sh` runs every `runtime/tests/test-*.sh` and exits non-zero if any fails; each test script uses `assert_eq <expected> <actual> <label>` defined in `run-tests.sh` and exported.
- Produces: the runtime's `VERSION` file gains `build=$RUNTIME_BUILD`.

- [ ] **Step 1: Write the failing tests in `runtime/tests/test-config.sh`**

```bash
assert_eq "cx26.3"   "$(STEPOVER_CX_VERSION=26.3.0 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "build 1 name"
assert_eq "cx26.3-2" "$(STEPOVER_CX_VERSION=26.3.0 STEPOVER_RUNTIME_BUILD=2 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "build 2 name"
assert_eq "cx26.4.1" "$(STEPOVER_CX_VERSION=26.4.1 bash -c 'source runtime/config.sh; echo $RUNTIME_NAME')" "patch version name"
assert_eq "26.3.0"   "$(bash -c 'source runtime/config.sh; echo $CX_VERSION')" "default version unchanged"
assert_eq "/x/src"   "$(STEPOVER_SOURCES=/x/src bash -c 'source runtime/config.sh; echo $SOURCES')" "sources override"
# Review Focus 2: a changed archive under a pinned checksum is refused and removed
tmp=$(mktemp -d); echo changed > "$tmp/crossover-sources-26.3.0.tar.gz"
STEPOVER_DOWNLOADS="$tmp" bash -c 'source runtime/config.sh; fetch "file:///dev/null" "$CX_SHA256" crossover-sources-26.3.0.tar.gz' 2>"$tmp/err" && status=0 || status=$?
assert_eq "1" "$status" "changed archive refused"
assert_eq "checksum mismatch: $tmp/crossover-sources-26.3.0.tar.gz" "$(cat "$tmp/err")" "mismatch message"
assert_eq "no" "$([ -f "$tmp/crossover-sources-26.3.0.tar.gz" ] && echo yes || echo no)" "bad archive removed"
```

- [ ] **Step 2: Run them to see them fail**

Run: `bash runtime/tests/run-tests.sh`
Expected: FAIL on "build 2 name" (and "sources override").

- [ ] **Step 3: Make the `config.sh` changes and add `build=` to `VERSION`; write `runtime/fetch-sources.sh`**

- [ ] **Step 4: Run the tests**

Run: `bash runtime/tests/run-tests.sh`
Expected: every assertion prints `ok`, exit 0.

- [ ] **Step 5: Run `fetch-sources.sh` against the cached archive**

Run: `STEPOVER_SOURCES=$(mktemp -d) runtime/fetch-sources.sh`
Expected: prints `Wine version 11.0` (from the archive already in `downloads/`, no network needed).

- [ ] **Step 6: Commit**

```bash
git add runtime/config.sh runtime/install-runtime.sh runtime/fetch-sources.sh runtime/tests/run-tests.sh runtime/tests/test-config.sh
git commit -m "runtime: version overrides, build numbers, fetch-sources.sh"
```

### Task 3: Runtime ordering in the app

**Files:**
- Modify: `app/Sources/StepoverKit/Runtime.swift:32-40`
- Test: `app/Tests/StepoverKitTests/StepoverKitTests.swift`

**Interfaces:**
- Produces: `public static func ordered(_ names: [String]) -> [String]` on `Runtime`: drops names starting with `.` or ending in `.new` or `.old`, sorts oldest first with `compare(_:options: .numeric)`. `installed()` uses it.

- [ ] **Step 1: Write the failing test**

```swift
func testRuntimeOrderWithBuildNumbers() {
    XCTAssertEqual(Runtime.ordered(["cx26.4", "cx26.3-10", "cx26.3", "cx26.3-2", "cx26.4.1", "cx26.3.old", "cx26.4.new", ".DS_Store"]),
                   ["cx26.3", "cx26.3-2", "cx26.3-10", "cx26.4", "cx26.4.1"])
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd app && swift test --filter testRuntimeOrderWithBuildNumbers`
Expected: FAIL, `ordered` not defined.

- [ ] **Step 3: Add `Runtime.ordered` and use it in `installed()`**

- [ ] **Step 4: Run all tests**

Run: `cd app && swift test 2>&1 | grep "Executed .* tests" | tail -1`
Expected: `Executed 33 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/StepoverKit/Runtime.swift app/Tests/StepoverKitTests/StepoverKitTests.swift
git commit -m "Runtime.ordered: build-numbered names sort correctly"
```

### Task 4: D3DMetal from a published runtime

**Files:**
- Modify: `runtime/install-runtime.sh:38-56` (the D3DMetal section)
- Test: `runtime/tests/test-d3dmetal.sh`

**Interfaces:**
- Produces: `STEPOVER_D3DMETAL_ARCHIVE` (path to a `stepover-runtime-*.tar.xz`). When set, `install-runtime.sh` copies `<name>/lib/d3dmetal` and `<name>/licenses/d3dmetal` out of that archive instead of mounting the Game Porting Toolkit image, and fails with `no D3DMetal in <archive>` if either is missing. `D3DM_VERSION` is read from the same `Info.plist` path as today. When unset, behavior is unchanged.

- [ ] **Step 1: Write the failing test `runtime/tests/test-d3dmetal.sh`**

Two cases, run only when `build/wine-install` exists (print `skip` otherwise): (a) with `STEPOVER_D3DMETAL_ARCHIVE=release/dist/0.2.2/stepover-runtime-cx26.3.tar.xz` and `STEPOVER_RUNTIMES=$(mktemp -d)`, `install-runtime.sh` exits 0 and `diff -r` of the new runtime's `lib/d3dmetal` against `~/Library/Application Support/Stepover/Runtimes/cx26.3/lib/d3dmetal` prints nothing; (b) with `STEPOVER_D3DMETAL_ARCHIVE` pointing at a 1-byte file, it exits non-zero and stderr contains `no D3DMetal in` (Review Focus 3).

- [ ] **Step 2: Run it to see case (a) fail**

Run: `bash runtime/tests/run-tests.sh`
Expected: FAIL in test-d3dmetal (the archive is ignored and the disk image path is used or missing).

- [ ] **Step 3: Implement the archive branch in `install-runtime.sh`**

Extract with `tar -xJf "$archive" -C "$tmp" --include='*/lib/d3dmetal/*' --include='*/licenses/d3dmetal/*'`, then `ditto` both folders into `$STAGE`.

- [ ] **Step 4: Run the tests**

Run: `bash runtime/tests/run-tests.sh`
Expected: all `ok`. Then `rm -rf` the temporary runtimes folder.

- [ ] **Step 5: Commit**

```bash
git add runtime/install-runtime.sh runtime/tests/test-d3dmetal.sh
git commit -m "install-runtime: take D3DMetal from a published runtime"
```

### Task 5: Detecting new versions

**Files:**
- Create: `runtime/latest-crossover.sh`, `runtime/addon-versions.sh`
- Create: `runtime/tests/test-detect.sh`, `runtime/tests/fixtures/codeweavers-source.html`, `runtime/tests/fixtures/addons.c`

**Interfaces:**
- Produces: `runtime/latest-crossover.sh [html-file]` prints the newest `X.Y.Z` found as `crossover-sources-X.Y.Z.tar.gz` on `https://www.codeweavers.com/crossover/source` (or in the given file). Only names matching exactly `crossover-sources-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz` count; compared with `sort -t. -k1,1n -k2,2n -k3,3n`. Exit 1 with `no CrossOver source found` when none match.
- Produces: `runtime/addon-versions.sh <wine source dir>` prints two lines, `MONO_VERSION=<v>` and `GECKO_VERSION=<v>`, from the `#define MONO_VERSION "…"` and `#define GECKO_VERSION "…"` lines of `dlls/appwiz.cpl/addons.c`; exit 1 if either is missing.

- [ ] **Step 1: Write the fixtures and the failing tests**

Fixture HTML contains links to `crossover-sources-26.3.0.tar.gz`, `crossover-sources-26.9.0.tar.gz`, `crossover-sources-26.10.0.tar.gz` and `crossover-sources-26.11.0-beta1.tar.gz`. Fixture `addons.c` contains `#define GECKO_VERSION "2.47.4"` and `#define MONO_VERSION "10.4.1"`.

```bash
assert_eq "26.10.0" "$(runtime/latest-crossover.sh runtime/tests/fixtures/codeweavers-source.html)" "newest stable wins (Review Focus 1)"
assert_eq $'MONO_VERSION=10.4.1\nGECKO_VERSION=2.47.4' "$(runtime/addon-versions.sh runtime/tests/fixtures)" "addon versions"
assert_eq "1" "$(runtime/latest-crossover.sh /dev/null >/dev/null 2>&1; echo $?)" "nothing found"
```

(`addon-versions.sh` takes the folder that contains `dlls/appwiz.cpl/addons.c`; put the fixture at `runtime/tests/fixtures/dlls/appwiz.cpl/addons.c`.)

- [ ] **Step 2: Run them to see them fail**

Run: `bash runtime/tests/run-tests.sh`
Expected: FAIL, scripts missing.

- [ ] **Step 3: Write both scripts**

- [ ] **Step 4: Run the tests, then the live page**

Run: `bash runtime/tests/run-tests.sh && runtime/latest-crossover.sh && runtime/addon-versions.sh sources/sources/wine`
Expected: all `ok`; then `26.3.0` (or newer, if CodeWeavers has published since); then `MONO_VERSION=10.4.1` and `GECKO_VERSION=2.47.4`.

- [ ] **Step 5: Commit**

```bash
git add runtime/latest-crossover.sh runtime/addon-versions.sh runtime/tests/test-detect.sh runtime/tests/fixtures
git commit -m "runtime: detect new CrossOver source and its Mono and Gecko versions"
```

### Task 6: Checking a built runtime

**Files:**
- Create: `runtime/check-runtime.sh`, `runtime/tests/hello.c`
- Test: `runtime/tests/test-check.sh`

**Interfaces:**
- Consumes: the `stepover` command built from `app/` (`swift build -c release --product stepover`), passed as `STEPOVER_CLI` or found at `app/.build/release/stepover`.
- Produces: `runtime/check-runtime.sh <runtime dir> [--previous <runtime dir>] [--metal]`. Runs with `STEPOVER_HOME`, `STEPOVER_LOGS` and `STEPOVER_LAUNCHERS` in a temporary folder (logs and launchers don't live under `STEPOVER_HOME`, see `Paths.swift`), `STEPOVER_RUNTIMES` set to a folder holding the runtime(s) and `STEPOVER_RUNTIME` set to the runtime's name, and deletes the temporary folder on exit. Prints `ok <check>` or `FAIL <check>: <reason>` for each check and exits 1 at the first failure. Checks:
  - `files`: `bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/cxcompatdb.so`, `lib/d3dmetal/external/D3DMetal.framework`, `lib/dxmt/x86_64-windows`, `lib/dxvk/x86_64-windows` (if `VERSION` has a `dxvk=` other than `none`), `share/wine/mono`, `share/wine/gecko`. The reason names the missing path.
  - `boot`: `stepover create check` exits 0 within 300 seconds.
  - `program`: `hello.exe` (built from `runtime/tests/hello.c` with `x86_64-w64-mingw32-gcc`, prints `stepover-check` and returns 0) copied to the bottle's `drive_c` and run with `stepover run check 'C:\hello.exe' --wait`; exit 0 and the bottle log contains `stepover-check`.
  - `plugin`: the same run with `STEPOVER_COMPAT_DEBUG=1`; the bottle log contains `stepover-compat: hello.exe: backend`.
  - `previous` (with `--previous`): a bottle created with the previous runtime (`STEPOVER_RUNTIME=<previous name>`) runs `hello.exe` on the new runtime, exit 0.
  - `metal` (with `--metal`): Task 7.

- [ ] **Step 1: Write the failing test `runtime/tests/test-check.sh`**

Skips unless `~/Library/Application Support/Stepover/Runtimes/cx26.3` exists. (a) `check-runtime.sh` on a clone (`cp -Rc`) of it prints `ok files`, `ok boot`, `ok program`, `ok plugin` and exits 0; (b) on a clone with `lib/d3dmetal` removed it exits 1 and prints `FAIL files: missing lib/d3dmetal/external/D3DMetal.framework` (Review Focus 4). Clones go in a temporary folder that the test removes.

- [ ] **Step 2: Run it to see it fail**

Run: `bash runtime/tests/run-tests.sh`
Expected: FAIL, `check-runtime.sh` missing.

- [ ] **Step 3: Write `hello.c` and `check-runtime.sh`**

- [ ] **Step 4: Run the tests**

Run: `bash runtime/tests/run-tests.sh`
Expected: all `ok`. No bottles appear under the real `~/Library/Application Support/Stepover/Bottles`.

- [ ] **Step 5: Commit**

```bash
git add runtime/check-runtime.sh runtime/tests/hello.c runtime/tests/test-check.sh
git commit -m "runtime: check-runtime.sh, automated checks for a built runtime"
```

### Task 7: Direct3D checks (only if the spike found Metal)

Skip this task, and leave `--metal` printing `skip metal: no Metal device`, if `docs/runtime-ci-spike.md` says `metal=none`.

**Files:**
- Create: `runtime/tests/d3d11.c`, `runtime/tests/d3d12.c`
- Modify: `runtime/check-runtime.sh` (the `metal` check)

**Interfaces:**
- Produces: two Windows programs that open a hidden 64x64 window, create a device and swap chain (`D3D11CreateDeviceAndSwapChain`; `D3D12CreateDevice` plus a DXGI swap chain on a command queue), present one frame and exit 0, or print the failing `HRESULT` and exit 1. Built with `x86_64-w64-mingw32-gcc -ld3d11 -ldxgi` and `-ld3d12 -ldxgi`. The `metal` check runs both through `stepover run check … --wait` with the bottle's graphics set to D3DMetal (`stepover graphics check '*' d3dmetal`), and passes when both exit 0.

- [ ] **Step 1: Add `--metal` to `test-check.sh`, expecting `ok metal`**
- [ ] **Step 2: Run it; expect `FAIL metal` (programs missing)**
- [ ] **Step 3: Write both programs and the check**
- [ ] **Step 4: Run it on the maintainer's Mac; expect `ok metal`**
- [ ] **Step 5: Commit** (`git commit -m "check-runtime: Direct3D 11 and 12 through D3DMetal"`)

### Task 8: The runtime workflow

**Files:**
- Create: `.github/workflows/runtime.yml`

**Interfaces:**
- Consumes: `fetch-sources.sh`, `latest-crossover.sh`, `addon-versions.sh`, `check-runtime.sh`, `install-runtime.sh` with `STEPOVER_D3DMETAL_ARCHIVE`, the `config.sh` overrides.
- Produces: on success, a workflow artifact named `stepover-runtime-<name>` holding `stepover-runtime-<name>.tar.xz` (packed exactly as `release/make-release.sh` packs it), its `.sha256`, the runtime's `VERSION` and `check.log`.

Triggers: `schedule` (daily, `cron: "17 9 * * *"`), `workflow_dispatch` with input `force` (boolean: build the pinned version even with nothing new), and `push` to `runtime-ci/**` (development only; Plan 5 removes it). `permissions: contents: read`. `concurrency: runtime` with `cancel-in-progress: false`.

Job `detect` (`macos-15`): download and verify the pinned archive with `fetch-sources.sh`; a checksum mismatch fails the job here (Review Focus 2). Run `latest-crossover.sh`; if it is newer than `CX_VERSION`, download it and output `version` and `sha256` (from `shasum -a 256`); otherwise output the pinned values and `new=false`. `build` runs when `new` is true, on `force`, or on `push`.

Job `build` (`macos-15`, `timeout-minutes: 350`):
1. Checkout; install the Homebrew packages from Task 1; install Rosetta if missing.
2. Set `STEPOVER_SRC=$GITHUB_WORKSPACE`, `STEPOVER_BUILD`, `STEPOVER_DOWNLOADS`, `STEPOVER_SOURCES` and `STEPOVER_RUNTIMES` under `$RUNNER_TEMP`, and `STEPOVER_CX_VERSION`/`STEPOVER_CX_SHA256` from `detect`.
3. `fetch-sources.sh`; `addon-versions.sh "$STEPOVER_SOURCES/sources/wine"`; for a Mono or Gecko version that differs from `config.sh`, download it from `dl.winehq.org` and export the new version and `shasum -a 256` values (spec section 1, trust on first download).
4. Download the newest published runtime: read `SHA256SUMS` of the latest release (`gh release download --repo "$GITHUB_REPOSITORY" --pattern SHA256SUMS`), take the `stepover-runtime-*.tar.xz` line, download that asset and verify it; export `STEPOVER_D3DMETAL_ARCHIVE`, and unpack it as the previous runtime for the `previous` check.
5. `build-deps.sh`, `build-wine.sh`, `build-dxvk.sh`, `install-runtime.sh`; `swift build -c release --package-path app --product stepover`.
6. `check-runtime.sh "$STEPOVER_RUNTIMES/<name>" --previous <previous runtime> [--metal if the spike found Metal] | tee check.log`.
7. Only after the checks pass: pack, write the `.sha256`, upload the artifact (retention 30 days), and write the runtime summary, check results and build minutes to `$GITHUB_STEP_SUMMARY`.

- [ ] **Step 1: Write `runtime.yml`**
- [ ] **Step 2: Lint it**

Run: `brew install actionlint && actionlint .github/workflows/runtime.yml .github/workflows/runtime-spike.yml`
Expected: no output.

- [ ] **Step 3: Commit** (`git commit -m "runtime CI: detect, build, check, keep the runtime as an artifact"`)

### Task 9: End-to-end run

- [ ] **Step 1: Push and let the `push` trigger build the pinned 26.3.0 (maintainer's OK first)**

Run: `git push origin HEAD:runtime-ci/pipeline`, then `gh run watch` on the `Runtime` run.
Expected: `detect` passes; `build` passes every check; the artifact `stepover-runtime-cx26.3` exists.

- [ ] **Step 2: Compare it with the runtime built on the Mac**

Run: `gh run download <run id> --repo rudolphh/stepover --dir $(mktemp -d)`, unpack the archive, and `diff -rq` it against `~/Library/Application Support/Stepover/Runtimes/cx26.3`, ignoring `VERSION`.
Expected: the same file list; differing binaries are listed for the record (signatures and timestamps), not treated as failure.

- [ ] **Step 3: Install it beside the real runtime and play one game (maintainer)**

Run: `STEPOVER_RUNTIMES=$(mktemp -d) stepover runtime install --from <archive>` then the maintainer starts one game with `STEPOVER_RUNTIMES` pointing there.
Expected: the game runs as it does on the Mac-built runtime.

- [ ] **Step 4: Record build minutes, peak disk and check results in `docs/runtime-ci-spike.md`; commit**

```bash
git add docs/runtime-ci-spike.md
git commit -m "runtime CI: first end-to-end build"
```
