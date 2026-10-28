# Runtime List and Side-by-Side Runtimes Implementation Plan (plan 2 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app learns which runtimes exist from a list on GitHub, installs new ones next to the old ones, lets each bottle choose its Wine version, and can be told a runtime is bad, so users always have a one-click way back before anything is published automatically.

**Architecture:** A `runtime/index.json` file on `main` lists every runtime. `RuntimeManifest` grows the list's extra fields, `RuntimeIndex` loads it (cached copy, else the app's bundled entry) and fetches it from GitHub. A pure `Runtime.choose` decides each bottle's runtime from its pin, the runtime it last ran on, what's installed and what's pulled. The app's bottle page gets a Wine version picker, and a Runtimes window lists installed runtimes with Remove. The compat plug-in gains a format number so old runtimes and new apps can tell what they can apply.

**Tech Stack:** Swift 5.10 (`app/`, SwiftUI, XCTest), C (`compat/stepovercompat.c`), bash (`runtime/`, `release/`).

**Spec:** `docs/superpowers/specs/2026-10-27-automatic-runtime-builds-design.md` (sections 4 app side, 5, 10; the roadmap is `docs/superpowers/plans/2026-10-27-runtime-builds-roadmap.md`)

## Global Constraints

- macOS 14 minimum (`Package.swift` `.macOS(.v14)`); Swift tools 5.10.
- Work on a new branch from `main` (f6d9734 or later) in a worktree under `.worktrees/`. `main` has 33 app tests and the shell suite `bash runtime/tests/run-tests.sh`.
- "Runtimes are published independently of the app. A new CrossOver source drop never needs a new app release" (spec, Goals 2).
- "Update available downloads the new runtime into its own folder; nothing is replaced or deleted" (spec 5).
- "Stepover keeps the two newest good runtimes. Older ones are listed with a Remove button" (spec 5).
- "`Newest` skips pulled runtimes for new downloads, but never moves a bottle by itself" (spec 5).
- "The runtime belongs to the bottle, not the game": prompts and the picker name the bottle (spec 5).
- The index lives at `runtime/index.json` on `main`, read over HTTPS from the repository in the app's `StepoverSourceURL`; `STEPOVER_RUNTIME_INDEX` (a URL or a file path) overrides it. No separate signature (spec 4, maintainer-approved call).
- Index `status` values: `current`, `available`, `pulled` (spec 4).
- Every value that differs per machine or fork comes from an environment variable or the app's Info.plist, with today's value as the default (operator rule).
- No em dashes in prose, comments or UI copy. UI copy is plain and short.
- Do not commit, push or publish without the maintainer's OK; the release task (Task 8) needs it explicitly.

## Review Focus

1. Offline at launch, or GitHub returns an error: the app quietly uses the cached list (else the bundled entry); no alert, nothing breaks. Test in Task 1.
2. A malformed or truncated index arrives: the previous cached copy stays; nothing is wiped. Test in Task 1.
3. An index entry whose `name` isn't a plain folder name (`../x`, `a/b`, empty) or whose `url` isn't HTTPS: the entry is dropped, because the name becomes a folder under Runtimes. Test in Task 1.
4. The user removes a runtime a running bottle is using: refused, naming the bottle. Test in Task 4.
5. An app older than a runtime's `minApp` (or a dev build with no version): the runtime isn't offered and nothing crashes; a dev build counts as new enough. Test in Task 3.

---

### Task 1: The runtime list

**Files:**
- Modify: `app/Sources/StepoverKit/RuntimeInstaller.swift` (`RuntimeManifest`)
- Create: `app/Sources/StepoverKit/RuntimeIndex.swift`
- Create: `runtime/index.json`
- Test: `app/Tests/StepoverKitTests/RuntimeIndexTests.swift`

**Interfaces:**
- Produces: `RuntimeManifest` gains optional `released: String?`, `status: RuntimeStatus?` (`enum RuntimeStatus: String, Codable { case current, available, pulled }`), `note: String?`, `minApp: String?`, `compatFormat: Int?`. Existing fields and `bundled()` are unchanged; a missing `status` decodes as nil and counts as `current`.
- Produces: `public struct RuntimeIndex: Codable, Sendable { public var runtimes: [RuntimeManifest] }` with
  - `public var current: RuntimeManifest?`: the last entry whose status is `current` (or nil status);
  - `public var pulled: Set<String>`: names with status `pulled`;
  - `public static func decode(_ data: Data) -> RuntimeIndex?`: nil for invalid JSON; drops entries whose `name` doesn't match `^[A-Za-z0-9][A-Za-z0-9._-]*$` or contains `..`, and entries whose `url` isn't `https://` (a `file://` URL or plain path is allowed only when `STEPOVER_RUNTIME_INDEX` is a file path, for tests and local builds);
  - `public static var cacheFile: URL` = `Paths.root/runtime-index.json`;
  - `public static func load() -> RuntimeIndex`: the cache if it decodes, else `RuntimeIndex(runtimes: [RuntimeManifest.bundled()].compactMap { $0 })`;
  - `public static var source: String`: `STEPOVER_RUNTIME_INDEX`, else `https://raw.githubusercontent.com/<owner>/<repo>/main/runtime/index.json` from `StepoverSourceURL`, else `rudolphh/stepover`;
  - `public static func fetch() async -> Bool`: reads `source`, writes the cache atomically only if `decode` succeeds and lists at least one runtime; returns whether it updated. Never throws.
- Produces: `runtime/index.json` with one entry: `cx26.3`, url `https://github.com/rudolphh/stepover/releases/download/v0.2.2/stepover-runtime-cx26.3.tar.xz`, sha256 `18e87ca7dc974796d2c4297b24ee7f1bbf920921e84c9870d3d04a884bbbfac3`, size `289986340`, summary `Wine version 11.0, D3DMetal 4.0b3, DXMT 0.80, DXVK 1.10.3`, released `2026-10-27`, status `current`, minApp `0.2.0`, compatFormat `3`.

- [ ] **Step 1: Write the failing tests**

```swift
func testIndexDecodesAndPicksCurrent()            // two entries, cx26.3 available + cx26.4 current -> current.name == "cx26.4"
func testIndexMissingStatusCountsAsCurrent()      // one entry with no status -> current.name == that entry
func testIndexDropsUnsafeEntries()                // names "../x", "a/b", "" and url "http://x" dropped; "cx26.4-2" kept (Review Focus 3)
func testIndexPulledNames()                       // pulled == ["cx26.4"]
func testRepositoryIndexFileIsValid()             // decode(contents of runtime/index.json) has current.name "cx26.3", sha256 "18e87ca7…fac3"
func testFetchKeepsCacheOnBadData() async         // cache holds a valid index; STEPOVER_RUNTIME_INDEX -> a file with "{" ; fetch() == false; load() unchanged (Review Focus 2)
func testFetchFromUnreachableSourceKeepsCache() async  // STEPOVER_RUNTIME_INDEX -> "https://127.0.0.1:9/index.json"; fetch() == false; load() unchanged (Review Focus 1)
func testFetchWritesCache() async                 // file source with a valid index -> fetch() == true; load().current?.name matches
```

Tests that need `STEPOVER_HOME` or `STEPOVER_RUNTIME_INDEX` set them with `setenv` in `setUp` to a temporary folder and `unsetenv` in `tearDown` (`Paths` reads the environment on each access).

- [ ] **Step 2: Run them; expect compile failure (`RuntimeIndex` missing)**

Run: `cd app && swift test --filter RuntimeIndexTests 2>&1 | grep -E "error:|Executed" | head -3`

- [ ] **Step 3: Implement the fields, `RuntimeIndex`, and `runtime/index.json`**
- [ ] **Step 4: Run all tests; expect `Executed 41 tests, with 0 failures`**
- [ ] **Step 5: Commit** (`git commit -m "Runtime list: runtime/index.json and RuntimeIndex"`)

### Task 2: Choosing a bottle's runtime

**Files:**
- Modify: `app/Sources/StepoverKit/Runtime.swift`, `app/Sources/StepoverKit/Bottle.swift:55`, `app/Sources/StepoverKit/Launcher.swift` (`session`)
- Test: `app/Tests/StepoverKitTests/RuntimeChoiceTests.swift`

**Interfaces:**
- Consumes: `RuntimeIndex.load().pulled` (Task 1).
- Produces: `public static func choose(pinned: String?, lastUsed: String?, installed: [String], pulled: Set<String>, preferred: String?) -> String?` on `Runtime`, `installed` oldest first (`Runtime.ordered`). Rules, first match wins:
  1. `pinned` is installed: `pinned`.
  2. `preferred` (`STEPOVER_RUNTIME`) is installed: `preferred`.
  3. `lastUsed` is installed and pulled: `lastUsed` (a bottle is never moved off a pulled runtime by itself).
  4. The newest installed name not in `pulled`.
  5. The newest installed name.
  6. nil.
- Produces: `public var lastRuntime: String?` on `Bottle` (get and set), stored in `<bottle>/.stepover-last-runtime` (one line), not in `stepover.json`, because the app and the `stepover` command both write `stepover.json` and the app's in-memory copy would overwrite it.
- Produces: `Bottle.runtime(_ config:)` uses `choose` with `Runtime.installed()`, `RuntimeIndex.load().pulled`, `Paths.defaultRuntimeName`; `Runtime.resolve(_:)` keeps its signature for callers without a bottle and uses `choose(pinned: name, lastUsed: nil, …)`.
- Produces: `Launcher.session` sets `bottle.lastRuntime = runtime.name` when it differs. When `config.runtime` is set but not installed, it appends `pinned runtime <name> is missing; using <runtime>` to the bottle log.

- [ ] **Step 1: Write the failing tests**

```swift
func testPinnedWins()                 // choose(pinned: "cx26.3", lastUsed: nil, installed: ["cx26.3","cx26.4"], pulled: [], preferred: nil) == "cx26.3"
func testMissingPinFallsBack()        // pinned "cx26.2" not installed -> "cx26.4"
func testPreferredBeatsNewest()       // preferred "cx26.3" -> "cx26.3"
func testNewestSkipsPulled()          // installed ["cx26.3","cx26.4"], pulled ["cx26.4"], lastUsed nil -> "cx26.3"
func testStaysOnPulledItAlreadyUses() // same, lastUsed "cx26.4" -> "cx26.4"
func testAllPulledUsesNewest()        // pulled both -> "cx26.4"
func testNothingInstalled()           // installed [] -> nil
func testLastRuntimeRoundTrip()       // temp bottle folder: lastRuntime nil, set "cx26.4", read "cx26.4", file is ".stepover-last-runtime"
```

- [ ] **Step 2: Run them; expect compile failure**
- [ ] **Step 3: Implement `choose`, `Bottle.lastRuntime`, and the `Bottle.runtime`, `Runtime.resolve` and `Launcher.session` changes**
- [ ] **Step 4: Run all tests; expect `Executed 49 tests, with 0 failures`**
- [ ] **Step 5: Commit** (`git commit -m "Runtimes: each bottle keeps the runtime it's on; Newest skips pulled ones"`)

### Task 3: Offering and installing new runtimes side by side

**Files:**
- Modify: `app/Sources/StepoverKit/RuntimeInstaller.swift`, `app/Sources/StepoverApp/Store.swift` (runtime state, `installRuntime`), `app/Sources/StepoverApp/StepoverApp.swift` (sidebar Wine Runtime section, `RuntimeSetupView`), `app/Sources/stepover/main.swift` (`runtime` command)
- Test: `app/Tests/StepoverKitTests/RuntimeUpdateTests.swift`

**Interfaces:**
- Consumes: `RuntimeIndex` (Task 1), `Runtime.ordered` (plan 1).
- Produces on `RuntimeManifest`:
  - `public func supports(appVersion: String?) -> Bool`: true when `minApp` is nil, `appVersion` is nil (a dev build), or `appVersion >= minApp` comparing dot-separated numbers (`0.10.0 > 0.9.1`);
  - `public var neededBytes: Int64` = `size * 5 + 512 * 1_048_576` (archive, unpacked runtime about four times the archive, and a margin; about 2 GB for today's 290 MB archive).
- Produces: `public static func offered(index: RuntimeIndex, installed: [String], appVersion: String?) -> RuntimeManifest?` on `RuntimeInstaller`: `index.current` when it `supports(appVersion:)`, isn't pulled, and its name isn't installed; else nil.
- Produces: `RuntimeInstaller.install` checks `URL.resourceValues(.volumeAvailableCapacityForImportantUsageKey)` of `Paths.root` against `neededBytes` before downloading and throws `not enough disk space: the runtime needs about <N> GB free` when short. A runtime with a new name installs next to the others; the existing same-name replacement (with `.old`) stays for rebuilds of the same name.
- Produces in the app: `Store` loads `RuntimeIndex.load()` at start, then `await RuntimeIndex.fetch()` quietly and reloads. `runtimeUpdate` becomes `offered(...) != nil && running.isEmpty` (no update banner while a game runs). `installRuntime()` installs `offered(...)`, or for a first install `index.current`. The banner text names the new runtime: `Wine runtime <name> is available. A <size> download; your games keep their current runtime until you pick it.`
- Produces in the CLI: `stepover runtime status` lists every index entry (`name`, status, installed or not, note); `stepover runtime install [<name>] [--from <file or URL>]` installs the offered runtime, or the named index entry.

- [ ] **Step 1: Write the failing tests**

```swift
func testSupportsAppVersion()           // minApp "0.3.0": "0.2.2" false, "0.3.0" true, "0.10.0" true, nil true (dev build); minApp nil: "0.1.0" true (Review Focus 5)
func testNeededBytes()                  // size 289_986_340 -> 1_986_802_612 (289_986_340 * 5 + 536_870_912)
func testOfferedSkipsInstalledPulledAndTooNew()
                                        // current cx26.4 not installed -> offered cx26.4; installed -> nil;
                                        // status pulled -> nil; minApp "9.0.0" with app "0.3.0" -> nil
func testFailedInstallLeavesRuntimesAlone() async
                                        // temp STEPOVER_HOME with a fake runtime cx26.3 (bin/wine executable);
                                        // install a manifest for cx26.4 whose file is 1 byte with a wrong sha256;
                                        // throws; Runtime.installed() names == ["cx26.3"]; no cx26.4* folder left
```

- [ ] **Step 2: Run them; expect compile failure**
- [ ] **Step 3: Implement the installer and manifest additions, then the Store, sidebar banner, `RuntimeSetupView` and CLI changes**
- [ ] **Step 4: Run all tests; expect `Executed 53 tests, with 0 failures`**
- [ ] **Step 5: Check the CLI against a local index**

Run: `STEPOVER_RUNTIME_INDEX=$PWD/runtime/index.json app/.build/release/stepover runtime status` (after `swift build -c release --package-path app --product stepover`)
Expected: `cx26.3: current, installed` and nothing else.

- [ ] **Step 6: Commit** (`git commit -m "Runtimes: new ones install next to the old, offered from the runtime list"`)

### Task 4: The Runtimes window and removing runtimes

**Files:**
- Create: `app/Sources/StepoverKit/RuntimeCatalog.swift`, `app/Sources/StepoverApp/RuntimesView.swift`
- Modify: `app/Sources/StepoverApp/StepoverApp.swift` (menu item), `app/Sources/StepoverApp/Store.swift`, `app/Sources/stepover/main.swift`
- Test: `app/Tests/StepoverKitTests/RuntimeCatalogTests.swift`

**Interfaces:**
- Consumes: `Runtime.choose` / `Bottle.runtime`, `Bottle.lastRuntime` (Task 2), `RuntimeIndex.pulled` (Task 1).
- Produces in `RuntimeCatalog` (an `enum`):
  - `public static func kept(installed: [String], pulled: Set<String>) -> Set<String>`: the two newest names not in `pulled`;
  - `public static func users(of runtime: String, bottles: [(name: String, pinned: String?, resolved: String?)]) -> [String]`: bottle names pinned to it or currently resolving to it, sorted;
  - `public static func remove(_ runtime: Runtime, bottles: [Bottle]) throws`: throws `<bottle> is running on <runtime>; quit it first` if a bottle resolving to it `isRunning`; otherwise deletes the folder. Bottles pinned to it are left pinned (they fall back as Task 2 says) after the app has asked.
- Produces: a "Wine Runtimes…" item in the File menu (after Reload Bottles) opening `RuntimesView`: one row per installed runtime (name, summary, `Current`/`Available`/`Pulled` from the index with its note, "Used by: <bottles>"), and a Remove button on runtimes not in `kept`. Remove asks first when `users` isn't empty: `<names> use <runtime>. They will switch to <newest good>.`
- Produces: a pulled runtime's row also has **Switch its bottles to <suggested>** (newest installed runtime that isn't pulled), which does for every bottle using it what Task 5's per-bottle button does (spec 4: "a button to move every bottle that uses it back to the newest good runtime").
- Produces in the CLI: `stepover runtime remove <name>` (same rules; prints the bottles that switch).

- [ ] **Step 1: Write the failing tests**

```swift
func testKeepsTwoNewestGood()           // installed ["cx26.2","cx26.3","cx26.4","cx26.5"], pulled ["cx26.5"] -> kept == ["cx26.3","cx26.4"]
func testUsersArePinnedOrResolved()     // bottles [("A","cx26.3","cx26.3"), ("B",nil,"cx26.4"), ("C",nil,"cx26.3")] -> users(of: "cx26.3") == ["A","C"]
func testRemoveRefusesWhileRunning()    // temp home; bottle "Game" on cx26.3; a child process (/usr/bin/python3 -c with fcntl.lockf(LOCK_EX) then sleep) holds the lock file Bottle.isRunning checks (an in-process lock doesn't show to F_GETLK); remove throws "Game is running on cx26.3; quit it first"; folder still there (Review Focus 4)
func testRemoveDeletesIdleRuntime()     // same without the lock -> folder gone
```

- [ ] **Step 2: Run them; expect compile failure**
- [ ] **Step 3: Implement `RuntimeCatalog`, `RuntimesView`, the menu item and `stepover runtime remove`**
- [ ] **Step 4: Run all tests; expect `Executed 57 tests, with 0 failures`**
- [ ] **Step 5: Commit** (`git commit -m "Wine Runtimes window: see, keep and remove runtimes"`)

### Task 5: The Wine version picker on the bottle page

**Files:**
- Modify: `app/Sources/StepoverKit/RuntimeCatalog.swift`, `app/Sources/StepoverApp/StepoverApp.swift` (`BottleView`, the "Bottle" section and "About this bottle")
- Test: `app/Tests/StepoverKitTests/RuntimeCatalogTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4.
- Produces: `public enum BottleRuntimeState: Equatable` with cases `newest(String)`, `pinned(String, newer: String?)`, `missingPin(String, using: String?)`, `onPulled(String, note: String?, suggested: String?)`, `none`; and `public static func state(pinned: String?, resolved: String?, installed: [String], index: RuntimeIndex) -> BottleRuntimeState` in `RuntimeCatalog`. `onPulled` wins when `resolved` is pulled; `suggested` is the newest installed runtime that isn't pulled.
- Produces in `BottleView`'s "Bottle" section, above Default graphics: a **Wine version** picker with "Newest" (shows the name it resolves to) and each installed runtime (pulled ones marked "(pulled)"); choosing one sets `config.runtime` (nil for Newest). Under it, by state:
  - `pinned(_, newer: x)` with x non-nil: `On <name>; <x> is newer.` and a **Use Newest** button;
  - `missingPin`: `<name> isn't installed; using <using>.`;
  - `onPulled`: `<name> was pulled: <note>` and a **Switch to <suggested>** button, which sets `config.runtime = nil` and clears `bottle.lastRuntime`.
- "About this bottle" shows the resolved runtime's name next to its summary.

- [ ] **Step 1: Write the failing tests**

```swift
func testStateNewest()       // pinned nil, resolved "cx26.4", installed both -> .newest("cx26.4")
func testStatePinnedBehind() // pinned "cx26.3", resolved "cx26.3" -> .pinned("cx26.3", newer: "cx26.4")
func testStatePinnedLatest() // pinned "cx26.4" -> .pinned("cx26.4", newer: nil)
func testStateMissingPin()   // pinned "cx26.2", resolved "cx26.4" -> .missingPin("cx26.2", using: "cx26.4")
func testStateOnPulled()     // resolved "cx26.4" pulled with note "breaks RDR2" -> .onPulled("cx26.4", note: "breaks RDR2", suggested: "cx26.3")
```

- [ ] **Step 2: Run them; expect compile failure**
- [ ] **Step 3: Implement `state` and the picker**
- [ ] **Step 4: Run all tests; expect `Executed 62 tests, with 0 failures`**
- [ ] **Step 5: Commit** (`git commit -m "Bottle page: Wine version picker"`)

### Task 6: Compat format numbers (spec section 10)

**Files:**
- Modify: `compat/stepovercompat.c` (top comment and a `#define`), `runtime/install-runtime.sh` (VERSION), `app/Sources/StepoverKit/Config.swift` (`compatConf`), `app/Sources/StepoverKit/Runtime.swift`, `app/Sources/StepoverKit/Fix.swift`, `app/Sources/StepoverApp/StepoverApp.swift` (Fixes section)
- Test: `app/Tests/StepoverKitTests/FixTests.swift`, `runtime/tests/test-d3dmetal.sh`

**Interfaces:**
- Produces: `#define STEPOVER_COMPAT_FORMAT 3` in `stepovercompat.c` with a comment: 1 = `backend`, `env` (0.1.0); 2 = `args` (0.1.2); 3 = `dll` and full-path sections (0.2.0). The plug-in already ignores unknown keys, including the new `version` line.
- Produces: `install-runtime.sh` writes `compat_format=<n>` (read with `sed` from that `#define`) into the runtime's `VERSION`.
- Produces: `compatConf` writes `version = 3` (from `public static let compatFormat = 3` on `BottleConfig`) as the first line after the header comment, before `[*]`.
- Produces: `public var compatFormat: Int?` on `Runtime` (from `VERSION`'s `compat_format`; nil = unknown, treated as new enough).
- Produces: `public func neededCompatFormat(_ matched: MatchedFix) -> Int` on `Fix`: 3 if it has `dlls` or any key in `matched.programs` contains `\`; 2 if it has `args`; else 1.
- Produces in the Fixes section: for each applied fix whose `neededCompatFormat` exceeds the bottle runtime's known `compatFormat`, a caption: `<runtime> can't apply all of <fix name>; pick a newer Wine version.`

- [ ] **Step 1: Write the failing tests**

```swift
func testCompatConfStartsWithVersion()  // BottleConfig().compatConf() hasPrefix "# Written by Stepover from stepover.json; edit that file (or use the app) instead.\n\nversion = 3\n\n[*]\n"
func testNeededCompatFormat()           // dlls -> 3; Steam full-path key -> 3; args only -> 2; graphics/env only -> 1
```

and in `runtime/tests/test-d3dmetal.sh`: `assert_eq "yes" "$(grep -q '^compat_format=3$' "$tmp/runtimes/cx26.3/VERSION" && echo yes || echo no)" "VERSION records the compat format"`.

- [ ] **Step 2: Run them; expect failures**

Run: `cd app && swift test --filter FixTests 2>&1 | grep -E "error:|failed|Executed" | head` and `bash runtime/tests/run-tests.sh 2>&1 | grep FAIL`

- [ ] **Step 3: Implement the define, VERSION line, `version =` line, `Runtime.compatFormat`, `neededCompatFormat` and the caption**
- [ ] **Step 4: Run both suites; expect `Executed 64 tests, with 0 failures` and `all passed`**
- [ ] **Step 5: Commit** (`git commit -m "Compat format numbers: old runtimes say what they can't apply"`)

### Task 7: App releases stop carrying the runtime

**Files:**
- Modify: `release/make-release.sh`, `release/publish.sh`, `docs/how-it-works.md` ("The runtime download"), `README.md` (Install), `VERSION` (0.3.0, the version this plan ships as)

**Interfaces:**
- Consumes: `runtime/index.json` (Task 1).
- Produces: `make-release.sh` no longer packs the runtime. It writes `runtime.json` from the index's current entry (with `/usr/bin/python3 -I`), so a first launch offline still knows what to download, and it fails with `runtime/index.json has no current runtime` if there is none. `SHA256SUMS` lists only what the release carries. The cask caveat names the current entry's size.
- Produces: `make-release.sh` reads its downloads folder from `STEPOVER_DOWNLOADS` (default `$ROOT/downloads`), like `runtime/config.sh`.
- Produces: `publish.sh` uploads only the files that exist in `release/dist/<version>/` (no runtime archive is fine) and its release notes say the runtime comes from the runtime list.
- Produces: docs describing `runtime/index.json`, the cache in `<STEPOVER_HOME>/runtime-index.json`, `STEPOVER_RUNTIME_INDEX`, side-by-side runtimes, the Wine version picker and pulling a runtime.

- [ ] **Step 1: Make the release script changes**
- [ ] **Step 2: Build a release locally and check it**

Run: `zsh release/make-release.sh >/dev/null && ls release/dist/0.3.0 && /usr/bin/python3 -c 'import json;print(json.load(open("release/dist/0.3.0/runtime.json"))["name"])'` (make-release reads `VERSION`, now 0.3.0; run it from this worktree with `STEPOVER_DOWNLOADS=$HOME/.local/src/stepover/downloads`, since `downloads/` is git-ignored and only the main checkout has it)
Expected: no `stepover-runtime-*.tar.xz` in the listing; prints `cx26.3`. The folder stays for Task 8's release.

- [ ] **Step 3: Run both suites; expect them green**
- [ ] **Step 4: Commit** (`git commit -m "Releases: the app no longer carries the runtime"`)

### Task 8: Try it, then release 0.3.0 (maintainer's OK)

- [ ] **Step 1: Two runtimes side by side on the maintainer's Mac**

Repack the installed `cx26.3` as `cx26.3-2` in a scratch folder (rename the folder, `tar -cJ`), write a scratch index with `cx26.3` (`available`) and `cx26.3-2` (`current`, `url` the local file), and open a test build of the app with `STEPOVER_RUNTIME_INDEX` pointing at it.
Expected: the sidebar offers `cx26.3-2`; installing it leaves `cx26.3` untouched; bottles on Newest show `cx26.3-2`; pinning one to `cx26.3` shows `On cx26.3; cx26.3-2 is newer.`; marking `cx26.3-2` pulled in the scratch index (relaunch) shows the pulled note with **Switch to cx26.3** on bottles that ran on it; the Runtimes window lists both.

- [ ] **Step 2: The maintainer looks at the bottle page and the Runtimes window** (screenshots), then everything scratch is removed: the test runtime folder, the scratch index, and the test cache `runtime-index.json` if the test used the real home.
- [ ] **Step 3: With the maintainer's OK, merge, release 0.3.0 with `make-release.sh` and `publish.sh`, verify from the public tap (fresh install downloads `cx26.3` from the index; an existing install is offered nothing), and push `runtime/index.json` on `main`.**
