# Add a Game from an Installer or Folder: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag a game's installer folder (or installed game folder) onto Stepover, walk away, and come back to a Play button.

**Architecture:** Every rule is a pure function in StepoverKit with tests: cleaning a folder's name, telling installer kinds apart, deciding what a drop is, ranking the game's exe, the components its files need, the install watcher (hang-prone steps, the large-address fix, disk floor, stuck), the stage copy, the queue and the Trash offer. `AddGame` strings them into one pipeline that `stepover add` and the app both run, checked end to end with tiny Inno Setup and NSIS installers built for the test. The app adds the ways in (window drop, Dock drop, File menu, couch menu), install tiles in the Library and couch mode, and the Trash offer.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, XCTest, CryptoKit (MD5), zlib (CRC32), `hdiutil`, `cp -c`. Test fixtures only: mingw-w64 (already a build dependency), Homebrew `makensis`, Inno Setup 6's compiler run under Stepover's Wine.

**Spec:** `docs/superpowers/specs/2026-10-29-add-game-from-folder-design.md` (D1 to D13, anti-goals, Project 2 hooks, Appendix A). Builds on the Library (`2026-10-28-library-design.md`) and couch mode (`2026-10-28-couch-mode-design.md`).

## Global Constraints

- Package floor `.macOS(.v14)`, Apple frameworks only, no new Swift dependencies. Fixture tools are for tests only; nothing new at run time (winetricks already comes with the cask).
- Fixed copy (spec D1, D3, D5, D9, D12, D13): "Add Game from Installer or Folder…", "Drag a game's installer or folder here", "Unpack it first, then drag in the folder.", "Install Anyway", "Already in your Library", "Install Again", "Waiting to install", "Getting ready", "Copying, 12 GB of 40 GB", "Installing (12 GB so far)", "The installer needs you: it's open on the Mac", "Adding what the game needs", "Finding the game", "Paused: the disk is nearly full. Free up some space and it carries on.", "Interrupted", "Try Again", "The installer stopped with an error: <its message>.", "Some of the installer's files are damaged. Download them again, then Try Again.", "The installer stopped responding.", "Installed, but Stepover couldn't tell which program is the game.", "Choose the Game…", "This folder doesn't have an installer or a game in it.", "The folder isn't there anymore.", "Ready; the <add-on> add-on didn't install", "Move the installer to the Trash (frees 32 GB)", "Move the original folder to the Trash (frees 32 GB)", "Move to Trash", "Keep", "Add a Game", "Allow Stepover to see your Downloads on the Mac first". Added by this plan (my call, Review Focus 1): "This folder is still downloading. Try Again when it's done."
- No em dashes. Never "repack" in copy. No installer group's name in Stepover's code, copy or its own log lines; test fixtures use neutral names such as `GROUP` (spec anti-goals).
- No Wine words on the Library or couch mode: no "bottle", "prefix", "unarc", "Inno Setup" outside Details.
- Stepover never writes, moves or deletes anything in the dragged folder, except moving it to the Trash after the player says yes (D13).
- Nothing waits on a click mid-install except Install Anyway before starting and an installer that can't run silently (D3, D5).
- New bottles: 64-bit Windows 10, `WINEMSYNC=1`, High Resolution Mode on, DPI 96, Documents/Desktop/Downloads/Music/Pictures/Videos as real folders inside, Wine's menu builder off (D4). Existing bottles are not changed.
- Never WM_CLOSE a game; stuck Wine processes get SIGKILL.
- Scripted checks put `STEPOVER_HOME` under `~/Library/Caches/`, not `/private/...`: `RunningPrograms.inBottle` misses processes in bottles under `/private` (known bug, the maintainer's call, not fixed here). They point `STEPOVER_RUNTIMES` at the installed runtimes (read only) and set `STEPOVER_NO_CONTROLLER=1`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A folder dropped while it is still downloading or being copied (partial-download files, files changing): Stepover says "This folder is still downloading. Try Again when it's done." instead of installing broken files (my call, ledger it). Test in Task 3.
2. Names with `:`, `/`, `?`, quotes, `&`, apostrophes or accents ("Batman: Arkham Asylum", "Assassin's Creed", "Pokémon & Friends"): a valid bottle folder and `C:\Games\` folder, and silent arguments that quote correctly. Tests in Task 7.
3. The same folder dropped twice (window and Dock, or a double drop): one job, not two. Test in Task 8.
4. The drive holding the folder unplugged mid-install: "The folder isn't there anymore.", not a stall. Test in Task 5.
5. Stepover quit or crashed mid-install, then reopened: the tile says Interrupted with Try Again, and the half-made bottle shows no Play tile. Test in Task 8.

---

### Task 1: Spike: test installers and the Wine facts

**Files:**
- Create: `app/Tests/install/tinygame.c` (a Win32 window that imports `d3d11.dll` and closes after 3 s), `app/Tests/install/hang.c` (a console program that sleeps forever; built as `vc_redist.x64.exe`), `app/Tests/install/tiny-inno.iss`, `app/Tests/install/tiny-addon.iss`, `app/Tests/install/tiny-nsis.nsi`, `app/Tests/install/make-installers.sh`

`make-installers.sh <out dir>` builds, into `<out>`, with neutral names only:
- `Tiny.Game.v1.0.2-GROUP/` holding `setup.exe` plus `setup-1.bin` (Inno, `DiskSpanning=yes`), AppName "Tiny Game", installing `TinyGame.exe`, `UnityCrashHandler64.exe` (a copy of tinygame) and `_Redist/vc_redist.x64.exe` (hang), with a Start Menu shortcut, and a `[Run]` entry that runs the hang in silent mode; also `MD5/group-bins.md5` listing `..\setup-1.bin`.
- `Tiny NSIS Game/setup.exe` (NSIS, installs `TinyNsisGame.exe` plus a Start Menu shortcut).
- `Tiny GOG/` holding `setup_tiny_gog_1.0_(64bit)_(1).exe` (base) and `setup_tiny_gog_-_extra_1.0_(2).exe` (add-on, installs `Extra.txt` into the same folder).
- `Tiny Installed Game/` (TinyGame.exe, `unins000.exe`, `UnityCrashHandler64.exe`), `Empty/`, `Partial/` (`setup.exe` plus `setup-1.bin.part`), `tiny.zip`.

Inno's compiler: download the current Inno Setup 6 release (pin the URL and its SHA-256 in the script), install it silently into a scratch bottle with `stepover install`, and run `ISCC.exe` with `stepover wine`. NSIS: `brew install makensis` (test only).

- [ ] **Step 1:** Write the sources and the script; run `app/Tests/install/make-installers.sh ~/Library/Caches/stepover-fixtures`. Expected: every item above exists; `file` reports PE32 for each exe.
- [ ] **Step 2:** Record these facts in the ledger (each from a run, not a guess), installing `Tiny.Game...` by hand into a scratch bottle (`STEPOVER_HOME=~/Library/Caches/stepover-spike`):
  1. Does `sysctl KERN_PROCARGS2` on the running `setup.tmp` give the full Windows command line, including `/SL5="..."`? If not, does `wine wmic process get commandline` in the bottle? Whichever works is what Task 5's `RunningPrograms.arguments` uses.
  2. Appendix A's recipe on the tiny installer: pause `setup.tmp`, run an LAA-cleared copy with the loader's `/SL5` argument plus the silent arguments; does it finish and install `TinyGame.exe`? Does the copy's file name matter?
  3. `/LOG="C:\...\stepover-inno.log"`: is the log written, and what does an error line look like? (Corrupt a byte of `setup-1.bin` in a copy to make one.)
  4. The `[Run]` hang: does Inno wait on `vc_redist.x64.exe` until it's killed, then finish?
  5. Personal folders: after replacing the six links in `drive_c/users/crossover` with real folders holding `.stepover-keep`, does `wineboot -u` leave them as folders?
  Expected: 1 to 5 answered. If 2 fails, stop and bring it to the maintainer before Task 7.
- [ ] **Step 3: Commit** `"Add a game: test installers and the spike's script"`

### Task 2: The game's name and what it is

**Files:**
- Create: `app/Sources/StepoverKit/FolderName.swift`, `app/Sources/StepoverKit/Recognize.swift`
- Test: `app/Tests/StepoverKitTests/AddGameNameTests.swift`

**Interfaces:**
- Consumes: `GameIndex.match(name:exe:)`, `GameName.normalized`, `Verdicts.play(_:)`, `LibraryGame`.
- Produces:

```swift
public enum FolderName {
    /// The name a person would write, from a folder's or installer's file name. Generic rules only.
    public static func clean(_ raw: String) -> String
}
public struct Recognized: Equatable, Sendable { public var name: String; public var entry: GameEntry? }
public enum Recognize {
    /// The first candidate the games list (then `learned`) matches, named as the list names it; else the first non-empty candidate, entry nil.
    public static func game(candidates: [String], index: GameIndex, learned: GameIndex?) -> Recognized
    /// Only the firm no waits for Install Anyway: anti-cheat and no single-player (D3).
    public static func needsConfirmation(_ entry: GameEntry?) -> Bool
    /// The Library tile this game already is: same games-list entry id, else same normalized name; install tiles never count.
    public static func existing(_ game: Recognized, in library: [LibraryGame]) -> LibraryGame?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testCleanNames() {
    let cases = [
        "Escape from Duckov [Group Repack]": "Escape from Duckov",
        "Red.Dead.Redemption.2.Build.1436.28-GROUP": "Red Dead Redemption 2",
        "The.Witcher.3.Wild.Hunt.GOTY.v4.04-GROUP": "The Witcher 3 Wild Hunt GOTY",
        "Marvels.Spider-Man.Remastered-GROUP": "Marvels Spider-Man Remastered",
        "Spider-Man": "Spider-Man", "Half-Life 2": "Half-Life 2", "Hi Fi Rush": "Hi Fi Rush",
        "Sainthood v1.0.3 (64-bit)": "Sainthood",
        "setup_i_am_jesus_christ_1.0.2_(64bit)_(81234).exe": "i am jesus christ",
        "Game_Name_x64_Installer": "Game Name", "Tiny.Game.v1.0.2-GROUP": "Tiny Game",
    ]
    for (raw, clean) in cases { XCTAssertEqual(FolderName.clean(raw), clean, raw) }
}
func testRecognizeTriesEachCandidate()        // ["Some Folder", "Hi Fi Rush"] with a list holding "Hi-Fi RUSH" → name "Hi-Fi RUSH", entry set
func testRecognizeUnknownKeepsFirstName()     // no match → Recognized(name: "Tiny Game", entry: nil)
func testConfirmationOnlyForTheFirmNo()       // antiCheat + singlePlayer false → true; antiCheat + singlePlayer true → false; nil entry → false
func testExistingByEntryThenName()            // a program tile with the same entry id → that tile; same normalized name, no entry → that tile
```

- [ ] **Step 2:** Run `cd app && swift test --filter AddGameNameTests`. Expected: FAIL, `FolderName` not defined.
- [ ] **Step 3:** Implement both files. `clean` drops bracketed and parenthesized text; treats dots and underscores as separators when the name uses them that way; drops version tokens (`v4`, `1.0.2`, `Build 1436.28`), a trailing `-Tag` in dotted names when the tag has an inner capital, is all capitals or holds digits, and the words setup, installer, install, repack, x64, x86, 64-bit, 64bit, 32-bit, 32bit.
- [ ] **Step 4:** Run the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `"Add a game: the game's name from the folder, and what it already is"`

### Task 3: What was dropped

**Files:**
- Create: `app/Sources/StepoverKit/GameFolder.swift`
- Modify: `app/Sources/StepoverKit/PEFile.swift` (subsystem, product name, large-address flag)
- Test: `app/Tests/StepoverKitTests/GameFolderTests.swift`

**Interfaces:**
- Produces:

```swift
public enum InstallerKind: String, Codable, Sendable {
    case inno, nsis, msi, other
    public var label: String   // "Inno Setup installer", "NSIS installer", "Windows Installer package", "installer"
}
public struct Installer: Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case base, addOn, update }
    public var url: URL; public var kind: InstallerKind; public var role: Role
}
public enum DropPlan: Equatable, Sendable {
    case install([Installer])      // base, then add-ons by name, then updates in version order (D1b)
    case installedGame(URL)        // copied into the bottle (D1b)
    case several([URL])            // a folder of installer folders, each its own game
    case diskImage(URL)            // an .iso: AddGame.run mounts it read-only and plans its folder
    case archive, stillDownloading, nothing
}
public enum GameFolder {
    /// By what the file holds: Inno ("Inno Setup Setup Data"), NSIS ("NullsoftInst"), MSI (extension or OLE header); else `.other` for setup*/install* names; nil when it isn't an installer.
    public static func kind(of file: URL) -> InstallerKind?
    /// A folder, a setup .exe or .msi (the base; other installers beside it follow), or a mounted image's folder.
    public static func plan(for item: URL) -> DropPlan
    public static let partialExtensions: Set<String>   // part, crdownload, download, !qb, !ut, aria2, opdownload
}
extension PEFile {
    public var isWindowed: Bool            // optional header Subsystem == 2
    public var productName: String?        // VS_VERSIONINFO StringFileInfo "ProductName"
    /// The same file with IMAGE_FILE_LARGE_ADDRESS_AWARE (0x20) cleared in the COFF characteristics; nil if not a PE.
    public static func clearingLargeAddressAware(_ data: Data) -> Data?
}
```

- [ ] **Step 1: Write the failing tests** (temp folders; "installers" are small files with an `MZ` header and the marker text)

```swift
func testKindsBySignature()          // Inno marker → .inno; NullsoftInst → .nsis; "x.msi" → .msi; "setup.exe" without markers → .other; "TinyGame.exe" without markers → nil
func testInstallerFolderOrder()      // GOG names: base "setup_tiny_gog_1.0_(64bit)_(1).exe", add-on "setup_tiny_gog_-_extra_1.0_(2).exe",
                                     // updates "patch_tiny_gog_1.0_(1)_to_1.2_(3).exe", "patch_tiny_gog_1.2_(3)_to_1.10_(4).exe" → [base, addOn, update 1.2, update 1.10]
func testInstalledGameFolder()       // no installer at the top, a windowed exe two levels down → .installedGame(folder)
func testSeveralGames()              // parent holding "A/setup.exe" and "B/setup.exe" (Inno markers) → .several([A, B]);
                                     // a wrapper folder holding only "Game/setup.exe" → .install of Game's installers
func testArchiveEmptyAndPartial()    // "x.zip"/"x.rar"/"x.7z" → .archive; "x.iso" → .diskImage; empty folder → .nothing; folder with "setup-1.bin.part" → .stillDownloading
func testSingleSetupFileBringsItsFolder()   // plan(for: folder/setup_tiny_gog_...(1).exe) → base is that file, the add-on beside it follows
func testLargeAddressAwareCleared()  // a 0x200-byte PE header with characteristics 0x0122 → 0x0102; other bytes equal
func testWindowedAndProductName() throws   // Wine's notepad.exe from the installed runtime: isWindowed, productName "Wine" (XCTSkip without a runtime)
```

- [ ] **Step 2:** Run `swift test --filter GameFolderTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Search for markers in the whole file up to 64 MB, else its first and last 8 MB. "Windowed exe" uses `PEFile.isWindowed`, looking at most 3 folders deep.
- [ ] **Step 4:** Run the filter. Expected: PASS. Then `swift test` (all). Expected: PASS.
- [ ] **Step 5: Commit** `"Add a game: what was dropped"`

### Task 4: Finding the game, and what it needs

**Files:**
- Create: `app/Sources/StepoverKit/GameFinder.swift`, `app/Sources/StepoverKit/NeededComponents.swift`
- Test: `app/Tests/StepoverKitTests/GameFinderTests.swift`

**Interfaces:**
- Consumes: `PEFile` (`imports`, `isWindowed`), `Importer.programs(in:)` targets as `shortcuts`.
- Produces:

```swift
public struct ExeCandidate: Equatable, Sendable {
    public var path: String            // relative to the game folder, "/"-separated
    public var size: Int64
    public var windowed: Bool
    public var graphics: Bool          // imports d3d9, d3d11, d3d12, dxgi, opengl32 or vulkan-1
    public var fromShortcut: Bool
    public init(path: String, size: Int64, windowed: Bool, graphics: Bool, fromShortcut: Bool)
}
public enum GameFinder {
    public static func isExcluded(_ fileName: String) -> Bool
    /// Best first (D7): an exe the games list names; a shortcut's target; a top-level exe like the game's name (initials count: RDR2);
    /// the only top-level exe; the largest windowed exe that loads graphics. Excluded and console exes never appear.
    public static func rank(_ candidates: [ExeCandidate], gameName: String, knownExes: [String]) -> [ExeCandidate]
    public static func candidates(in folder: URL, shortcuts: [String]) -> [ExeCandidate]
}
public enum NeededComponents {
    /// winetricks verbs for DLLs the game's files import that Wine's builtins don't cover and the game doesn't ship (D6).
    public static func verbs(imports: Set<String>, shipped: Set<String>) -> [String]
    public static func scan(_ folder: URL) -> (imports: Set<String>, shipped: Set<String>)
    /// The game ships DLSS: turn on MetalFX (D8).
    public static func shipsDLSS(_ shipped: Set<String>) -> Bool
}
```

- [ ] **Step 1: Write the failing tests** (listings are the real folders on this Mac, `temp-*` leftovers left out)

```swift
func testRedDead() {   // RDR2.exe, PlayRDR2.exe, Launcher.exe, Uninstall/unins000.exe, x64/crashpad/release/crashpad_handler.exe
    XCTAssertEqual(GameFinder.rank(rdr2, gameName: "Red Dead Redemption 2", knownExes: ["RDR2.exe"]).first?.path, "RDR2.exe")
    XCTAssertEqual(GameFinder.rank(rdr2, gameName: "Red Dead Redemption 2", knownExes: []).first?.path, "RDR2.exe")
}
func testHiFiRush()    // Hi-Fi-RUSH.exe, Hibiki/Binaries/Win64/Hi-Fi-RUSH.exe, Uninstall/unins000.exe, Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe → "Hi-Fi-RUSH.exe"
func testIAmJesusChrist()   // unins000.exe, IMJCH.exe, _Redist/vc_redist.x86.exe, _Redist/dxwebsetup.exe, _Redist/vc_redist.x64.exe, _Redist/QuickSFV.EXE,
                            // IMJCH/Binaries/Win64/IMJCH-Win64-Shipping.exe → "IMJCH.exe"
func testSainthood()   // Sainthood.exe, unins000.exe, UnityCrashHandler64.exe, _Redist/dxwebsetup.exe, _Redist/QuickSFV.EXE → "Sainthood.exe"
func testDuckov()      // Duckov.exe, UnityCrashHandler64.exe, unins000.exe → "Duckov.exe"
func testNothingLeft() // only unins000.exe and vc_redist.x64.exe → []
func testComponents() {
    XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx11_43.dll", "d3dcompiler_43.dll"], shipped: []), ["d3dcompiler_43", "d3dx11_43"])
    XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx9_43.dll"], shipped: []), ["d3dx9"])
    XCTAssertEqual(NeededComponents.verbs(imports: ["xactengine3_7.dll", "x3daudio1_7.dll"], shipped: []), ["xact"])
    XCTAssertEqual(NeededComponents.verbs(imports: ["msvcp140.dll", "vcruntime140.dll"], shipped: []), [])
    XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx9_43.dll"], shipped: ["d3dx9_43.dll"]), [])
    XCTAssertTrue(NeededComponents.shipsDLSS(["nvngx_dlss.dll"]))
}
```

L.A. Noire's layout isn't on this Mac anymore; its need (`d3dx11_43`, `d3dcompiler_43`) is covered by `testComponents`. Ledger that.

- [ ] **Step 2:** Run `swift test --filter GameFinderTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. The table covers d3dx9_24 to 43, d3dx10*, d3dx11_42/43, d3dcompiler_43, xactengine*/x3daudio*/xapofx*, PhysXLoader/PhysXCore (`physx`); `scan` reads the imports of every exe and DLL in the folder (at most 2,000 files).
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Commit** `"Add a game: find the game, not the uninstaller, and what it needs"`

### Task 5: Watching an install, and what the tile says

**Files:**
- Create: `app/Sources/StepoverKit/InstallWatch.swift`, `app/Sources/StepoverKit/InstallStage.swift`
- Modify: `app/Sources/StepoverKit/RunningPrograms.swift` (arguments, CPU time)
- Test: `app/Tests/StepoverKitTests/InstallWatchTests.swift`

**Interfaces:**
- Consumes: `RunningPrograms.Process`, `InstallerKind`.
- Produces:

```swift
public enum InstallFailure: Codable, Hashable, Sendable {
    case installerError(String?), damaged, stoppedResponding, noGame, nothing, folderGone, archive, stillDownloading, interrupted
}
public enum InstallStage: Codable, Hashable, Sendable {
    case waiting, confirm, alreadyInLibrary(String), gettingReady, copying(done: Int64, total: Int64), installing(written: Int64),
         needsYou, addingComponents, findingGame, paused, failed(InstallFailure), done(addOnFailed: String?)
    public var text: String            // the Global Constraints copy; failures read as their sentence
    public var isActive: Bool          // gettingReady through findingGame, and paused
    public static func gigabytes(_ bytes: Int64) -> String   // "12 GB"
}
public struct InstallSample: Sendable {
    public var time: Double; public var processes: [RunningPrograms.Process]; public var cpuSeconds: Double
    public var written: Int64; public var free: Int64; public var sourceExists: Bool
}
public enum InstallAction: Equatable, Sendable {
    case end([Int32]), largeAddressFix(pid: Int32, windowsPath: String), pause([Int32]), resume([Int32]), stuck, sourceGone
}
public struct InstallWatch: Sendable {
    public static let floor: Int64 = 5_000_000_000, resumeAt: Int64 = 10_000_000_000
    public static let idleLimit = 600.0, busyLimit = 1_800.0, idleCPU = 0.02
    public static let hangProne: [String]   // dxwebsetup.exe, dxsetup.exe, vc_redist*.exe, vcredist*.exe, quicksfv.exe, ue4prereqsetup*.exe, ueprereqsetup*.exe
    public init(kind: InstallerKind, visible: Bool)
    public mutating func step(_ sample: InstallSample) -> [InstallAction]
}
extension RunningPrograms {
    public static func arguments(_ pid: Int32) -> [String]    // per the Task 1 spike: KERN_PROCARGS2, else wmic
    public static func cpuSeconds(_ pid: Int32) -> Double
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testHangProneStepsEndedOnce()   // vc_redist.x64.exe pid 40 → [.end([40])]; the same pid next sample → []
func testLargeAddressFixForInnoOnly()   // C:\users\crossover\Temp\is-AB12C.tmp\setup.tmp pid 7: .inno → [.largeAddressFix(7, path)] once; .nsis → []
func testDiskFloorPausesAndResumes()  // free 4 GB → [.pause(pids)]; 8 GB → []; 11 GB → [.resume(pids)]; starting under the floor pauses at once
func testStuckIdle()                  // written flat and CPU under 2% of a core for 600 s → [.stuck] once; growth at 599 s resets
func testStuckBusy()                  // written flat for 1,800 s at full CPU → [.stuck]
func testPausedAndVisibleNeverStuck() // paused time doesn't count; visible: true never reports .stuck
func testSourceGone()                 // sourceExists false → [.sourceGone] once
func testStageText() {
    XCTAssertEqual(InstallStage.installing(written: 12_000_000_000).text, "Installing (12 GB so far)")
    XCTAssertEqual(InstallStage.installing(written: 300_000_000).text, "Installing")
    XCTAssertEqual(InstallStage.copying(done: 12_000_000_000, total: 40_000_000_000).text, "Copying, 12 GB of 40 GB")
    XCTAssertEqual(InstallStage.failed(.installerError("Unarc.dll returned an error code: -11")).text,
                   "The installer stopped with an error: Unarc.dll returned an error code: -11.")
    XCTAssertEqual(InstallStage.done(addOnFailed: "Extra").text, "Ready; the Extra add-on didn't install")
    // and every other stage against its Global Constraints sentence
}
```

- [ ] **Step 2:** Run `swift test --filter InstallWatchTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `.largeAddressFix` matches `setup.tmp` under an `\is-*.tmp\` folder and never Stepover's own copy (`setup-stepover.tmp`). It applies to every Inno installer, not only the ones using unarc (my call, ledger it): unarc is unpacked into `is-*.tmp` only after `setup.tmp` has started, too late to tell, and Task 1 and Task 7's plain Inno fixture show the fix is harmless there. The outcome record still says "(unarc)" when `unarc.dll` appeared.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Commit** `"Add a game: watching an install, and the words on the tile"`

### Task 6: Checksums, the Downloads list, and the bottle's own folders

**Files:**
- Create: `app/Sources/StepoverKit/ChecksumCheck.swift`, `app/Sources/StepoverKit/DownloadsScan.swift`, `app/Sources/StepoverKit/BottleSetup.swift`
- Test: `app/Tests/StepoverKitTests/AroundInstallTests.swift`

**Interfaces:**
- Consumes: `GameFolder.plan(for:)`, `GameFolder.partialExtensions`, `Bottle`.
- Produces:

```swift
public enum ChecksumCheck {
    /// Files listed in .md5 and .sfv files (top level and one folder down; paths may start with ..\) that are missing or differ; nil when there are none.
    public static func damaged(in folder: URL) -> Int?
}
public enum DownloadsScan {
    /// Top-level folders and .iso files whose plan is .install or .installedGame, newest first; partial or changed in the last 60 s left out.
    public static func candidates(in folder: URL, now: Date = Date()) -> [URL]
}
public enum BottleSetup {
    public static let personal = ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"]
    /// Replaces Wine's links from C:\users\crossover to the Mac's folders with real folders holding `.stepover-keep` (D4).
    public static func keepPersonalFoldersInside(_ bottle: Bottle) throws
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testChecksums()          // MD5/group-bins.md5 lists ..\setup-1.bin and ..\setup-2.bin; one altered → 1; all good → 0; none → nil; .sfv with CRC32 → same
func testDownloadsList()      // Downloads with "Old Game/setup.exe" (Inno), "New Game/setup.exe" (newer), "Busy/setup-1.bin.part", "notes.txt", "x.iso"
                              // → ["New Game", "x.iso", "Old Game"] by modification date; "Busy" left out; a file touched 10 s ago leaves its folder out
func testPersonalFoldersInside() throws   // drive_c/users/crossover/Documents → link to a temp "home/Documents" holding a file;
                                          // after: a real folder with .stepover-keep; the home file still there
```

- [ ] **Step 2:** Run `swift test --filter AroundInstallTests`. Expected: FAIL.
- [ ] **Step 3:** Implement (CryptoKit `Insecure.MD5`, zlib `crc32`).
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Commit** `"Add a game: checksums, the Downloads list, folders inside the bottle"`

### Task 7: The pipeline and `stepover add`

**Files:**
- Create: `app/Sources/StepoverKit/AddGame.swift`, `app/Tests/install/add-check.sh`
- Modify: `app/Sources/StepoverKit/Importer.swift` (`create` takes `extraEnv`), `app/Sources/stepover/main.swift` (`add`), `docs/how-it-works.md` (Environment list only if a variable is added)
- Test: `app/Tests/StepoverKitTests/AddGameTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 to 6; `WindowsSetup.install` is not used for these installs (it waits without watching); `Launcher.wine(_:bottle:workdir:extraEnv:wait:)`, `Launcher.waitUntilIdle`, `Launcher.setDisplay`, `Launcher.applyFixes`, `Launcher.stop`, `WindowsSetup.installComponents`, `Importer.programs(in:)`, `GraphicsPicker.pick(exe:)`, `SteamLookup.learn`.
- Produces:

```swift
public struct AddGameError: Error, Equatable { public var failure: InstallFailure }
public struct InstallOutcome: Codable, Equatable, Sendable {   // <bottle>/stepover-install.json: the Project 2 hook
    public var job: String; public var stage: String; public var installers: [String]   // kind labels, "(unarc)" when unarc.dll appeared in is-*.tmp
    public var exitStatus: Int32?; public var fixes: [String]; public var components: [String]; public var seconds: Double
    public var logTail: [String]   // last 50 log lines, the source path as "<folder>" and the home folder as "~"
}
public enum AddGame {
    public typealias Report = @Sendable (InstallStage) -> Void
    public static func bottleName(for game: String) -> String        // Windows- and Finder-safe; "Name 2" when taken
    public static func installDir(for game: String) -> String         // C:\Games\<safe name>
    /// Inno: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="…" /LOG="…"; NSIS: /S then /D=… last, unquoted; MSI: msiexec /i … /qn TARGETDIR=… INSTALLDIR=…; other: [].
    public static func silentArguments(_ kind: InstallerKind, dir: String, log: String) -> [String]
    public static func recognize(_ item: URL, plan: DropPlan, index: GameIndex, learned: inout LearnedGames, lookUp: Bool, today: String) async -> Recognized
    /// Windows 10 64-bit, WINEMSYNC=1, High Resolution Mode at DPI 96, personal folders inside, winemenubuilder off (also during wineboot).
    public static func makeBottle(named name: String, job: String) throws -> Bottle
    /// Mounts an .iso first; runs the installers (or copies the game folder), watching with InstallWatch every 2 s; finds the game; sets graphics,
    /// MetalFX and components; runs Launcher.applyFixes; writes InstallOutcome. Keeps the Mac from idle sleep meanwhile. Throws AddGameError.
    public static func run(_ plan: DropPlan, source: URL, game: String, into bottle: Bottle, job: String, knownExes: [String],
                           report: Report) throws -> (program: Program, addOnFailed: String?)
    /// Deletes a bottle only when its stepover-install.json names this job.
    public static func discard(bottleNamed name: String, job: String) throws
}
```

`run`'s rules beyond the signatures:
- During installs `extraEnv["WINEDLLOVERRIDES"] = "winebrowser.exe=d"`; `Launcher.dropped` already removes `NoDefaultCurrentDirectoryInExePath` (D5).
- An installer is finished when its process has exited and `Launcher.waitUntilIdle` returns (D5).
- A component that fails to download doesn't fail the game: it goes into `failedComponents`, as fix components do.
- Stepover has no remove-game action yet, so D4's "its saves go with it" line has nowhere to go; ledger it for whoever adds one.
- `.largeAddressFix`: SIGSTOP the original, write `PEFile.clearingLargeAddressAware` of it as `setup-stepover.tmp` beside it, run that with the original's `/SL5=…` argument (`RunningPrograms.arguments`) plus the silent arguments, wait for it, then SIGKILL the paused original (Appendix A).
- `.end` and `.stuck` use SIGKILL; `.pause`/`.resume` SIGSTOP/SIGCONT the bottle's non-system programs; `.sourceGone` stops the bottle and fails with `.folderGone`.
- A failed base installer: when `ChecksumCheck.damaged(in:)` > 0 the failure is `.damaged`, else `.installerError` with the last error line of Inno's log (nil for other kinds). A failed add-on or update sets `addOnFailed` to its cleaned name and goes on.
- `.installedGame`: `cp -Rc` into `installDir`, reporting `.copying` from the copied size every 2 s.
- `.other` kinds run with no silent arguments, report `.needsYou`, and watch with `visible: true`.
- The program: `GameFinder.rank` over the install folder and the new shortcuts (exes new under `C:\Program Files*` too, when the installer ignored the folder); `GraphicsPicker.pick`; `D3DM_ENABLE_METALFX=1` when `shipsDLSS` and the pick is D3DMetal. None → `.noGame`.

- [ ] **Step 1: Write the failing tests**

```swift
func testSafeNames() {
    XCTAssertEqual(AddGame.bottleName(for: "Batman: Arkham Asylum"), "Batman - Arkham Asylum")
    XCTAssertEqual(AddGame.installDir(for: "What?/Why*"), #"C:\Games\What - Why"#)
    XCTAssertEqual(AddGame.installDir(for: "Assassin's Creed & Pokémon"), #"C:\Games\Assassin's Creed & Pokémon"#)
}
func testBottleNameTakenGetsANumber() throws   // with STEPOVER_BOTTLES at a temp folder holding "Tiny Game" → "Tiny Game 2"
func testSilentArguments() {
    XCTAssertEqual(AddGame.silentArguments(.inno, dir: #"C:\Games\A B"#, log: #"C:\l.log"#),
                   ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", #"/DIR="C:\Games\A B""#, #"/LOG="C:\l.log""#])
    XCTAssertEqual(AddGame.silentArguments(.nsis, dir: #"C:\Games\A B"#, log: "x"), ["/S", #"/D=C:\Games\A B"#])
}
func testDiscardOnlyItsOwnBottle() throws      // stepover-install.json job "j1": discard(job: "j2") throws and keeps it; "j1" deletes it
func testLogTailRedacted()                     // source "/Users/x/Downloads/Tiny" and home "/Users/x" in lines → "<folder>" and "~"
```

`add-check.sh <fixtures>` (end to end, `STEPOVER_HOME=~/Library/Caches/stepover-add-check-$$`, removed at the end) runs `stepover add` on each fixture and checks:
1. `Tiny.Game.v1.0.2-GROUP`: exit 0; bottle "Tiny Game" with program `C:\Games\Tiny Game\TinyGame.exe`; the hang was ended (log); the large-address fix ran (log); `Documents` is a folder; `user.reg` has `RetinaMode` "y" and `LogPixels` 96; `stepover-install.json` present; the fixture folder's `ls -lR` and checksums unchanged.
2. `Tiny NSIS Game`: exit 0, `TinyNsisGame.exe`. 3. `Tiny GOG`: base then add-on (`Extra.txt` present), one bottle.
4. `Tiny Installed Game`: copied, `TinyGame.exe` chosen, not `unins000.exe`. 5. A copy of `Tiny.Game...` with `setup-1.bin` altered: exit 1, "Some of the installer's files are damaged. Download them again, then Try Again."
6. `Empty`, `tiny.zip`, `Partial`: their sentences, no bottle left behind.

- [ ] **Step 2:** Run `swift test --filter AddGameTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `AddGame`, `Importer.create(_:extraEnv:)`, and `stepover add <path>...` (prints each stage's text; exit 1 on any failure; writes its jobs to `InstallQueue` with its pid as owner once Task 8 lands: until then, no queue).
- [ ] **Step 4:** Run the filter, then `swift test`. Expected: PASS.
- [ ] **Step 5:** Run `app/Tests/install/add-check.sh ~/Library/Caches/stepover-fixtures`. Expected: `6/6 passed`.
- [ ] **Step 6: Commit** `"Add a game: the install pipeline and stepover add"`

### Task 8: The queue and install tiles

**Files:**
- Create: `app/Sources/StepoverKit/InstallQueue.swift`
- Modify: `app/Sources/StepoverKit/Library.swift` (install tiles), `app/Sources/StepoverKit/Couch.swift` (actions on install tiles), `app/Sources/stepover/main.swift` (`add` records its jobs)
- Test: `app/Tests/StepoverKitTests/InstallQueueTests.swift`

**Interfaces:**
- Produces:

```swift
public enum TrashOffer: String, Codable, Sendable { case pending, kept, trashed, none }
public struct InstallJob: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String; public var source: String; public var name: String; public var entryID: String?; public var steam: Int?
    public var bottle: String?; public var stage: InstallStage; public var owner: Int32?; public var added: Date
    public var copiedGame: Bool; public var playedSeconds: Double; public var trashOffer: TrashOffer
}
public struct InstallQueue: Codable, Sendable {
    public var jobs: [InstallJob]
    public static var file: URL { get }          // <STEPOVER_HOME>/installs.json
    public static func load(from: URL = file) -> InstallQueue
    public func save(to: URL = file) throws
    /// Adds a waiting job, or returns the waiting or active job that already has this source (resolved path).
    public mutating func add(source: URL, name: String, entryID: String?, steam: Int?, copiedGame: Bool) -> InstallJob
    public func next() -> InstallJob?            // the first waiting job when none is active
    public mutating func markInterrupted(alive: (Int32) -> Bool)
}
public enum Afterwards {
    public static let goodRun = 600.0
    /// D13: done, pending, played ≥ goodRun, folder exists on a local volume, and no waiting or active job uses it.
    public static func shouldOffer(_ job: InstallJob, in queue: InstallQueue, exists: Bool, local: Bool) -> Bool
    public static func text(_ job: InstallJob, size: Int64) -> String
}
// Library.swift
//   LibraryGame.Kind gains `.install(InstallJob)`; tile id "install:<job id>".
//   Library.games(..., installs: [InstallJob]) puts tiles for jobs not done first, newest first; lookups include them by name.
// Couch.swift
public enum CouchAction { /* adds */ case tryAgain, installAnyway, playExisting(String), removeInstall }
extension Couch { public static func installAction(_ stage: InstallStage, button: CouchButton) -> CouchAction }
```

- [ ] **Step 1: Write the failing tests**

```swift
func testSameSourceOnce()          // add the same folder twice (and once through a symlink) → one job
func testNextIsOneAtATime()        // two waiting → next() is the first; with one active → nil
func testInterruptedAfterACrash()  // active job, owner not alive → .failed(.interrupted); owner alive (the CLI) → unchanged
func testHalfMadeBottleHasNoPlayTile()   // a job's bottle with no programs + the active job → one install tile, no program tile
func testInstallTilesFirst()       // two jobs and two played games → jobs newest first, then the games
func testTrashOffer()              // played 599 s → false; 600 s → true; kept → false; not local → false; another waiting job on it → false
func testTrashText()               // installer → "Move the installer to the Trash (frees 32 GB)"; copiedGame → "Move the original folder to the Trash (frees 32 GB)"
func testCouchOnInstallTiles()     // failed + A → .tryAgain; failed + B → .removeInstall; confirm + A → .installAnyway;
                                   // alreadyInLibrary("x") + A → .playExisting("x"); installing + A → .none
```

- [ ] **Step 2:** Run `swift test --filter InstallQueueTests`. Expected: FAIL.
- [ ] **Step 3:** Implement; `stepover add` now adds jobs (owner = its pid) and updates their stage.
- [ ] **Step 4:** Run the filter, then `swift test`, then `add-check.sh`. Expected: PASS, PASS, `6/6 passed`.
- [ ] **Step 5: Commit** `"Add a game: the queue and install tiles"`

### Task 9: The app: adding games and the Library

**Files:**
- Modify: `app/Sources/StepoverApp/Store.swift`, `app/Sources/StepoverApp/LibraryView.swift`, `app/Sources/StepoverApp/StepoverApp.swift`, `app/Sources/StepoverApp/DockMenu.swift` (AppDelegate), `app/build-app.sh` (Info.plist)
- Create: `app/Tests/ui/add-check.sh`

**Interfaces:**
- Consumes: `InstallQueue`, `AddGame`, `Afterwards`, `Recognize`, `InstallStage.text`.
- Produces (Store):

```swift
@Published var installs: [InstallJob]
func add(_ urls: [URL])                  // window drop, Dock, File menu, couch: recognize, queue, start the next
func installAnyway(_ job: InstallJob); func tryAgain(_ job: InstallJob); func removeInstall(_ job: InstallJob)
func chooseGame(_ job: InstallJob)       // the bottle's Add Program…
func moveSourceToTrash(_ job: InstallJob); func keepSource(_ job: InstallJob)
```

Behavior: `add` plans each item; `.several` queues each folder as its own job. It recognizes the game with `AddGame.recognize` (the Steam lookup only when View > Look Up Unknown Games on Steam is on). `Recognize.existing` gives `.alreadyInLibrary`, `Recognize.needsConfirmation` gives `.confirm`, everything else `.waiting`. One job at a time off the main thread; stage changes land on `installs` and `installs.json`; Try Again discards the job's bottle and queues it again; Remove discards it; finished jobs reload the Library so the program tile replaces the install tile. Quitting with a job active asks first ("A game is installing. Quit anyway? The install stops."; an on-screen message instead of an alert in couch mode), then stops the bottle and marks the job interrupted. While a done job's bottle runs, `playedSeconds` grows (the 2 s timer). `Afterwards.shouldOffer` puts the Trash line on the game's hero with Move to Trash and Keep. Info.plist declares the folder and the `.exe`, `.msi` and `.iso` types (UTIs as `mdls` reports them) with `LSHandlerRank` `None`, so Stepover accepts drops on its Dock icon but never becomes the default opener for `.exe` files. If SwiftUI opens a window per dropped file, use `handlesExternalEvents` to keep one window.

- [ ] **Step 1:** Implement the Store part and the File menu item, the drop destination on both views, `application(_:open:)`, the Info.plist types, the empty-screen line, and the install tiles' and hero's states (the tile's text is `stage.text`; buttons per state: Install Anyway, Play and Install Again, Try Again and Remove, Choose the Game…, and Details, which names the program Play runs and opens the log).
- [ ] **Step 2:** Write `app/Tests/ui/add-check.sh <fixtures> <games.json>`: build a Live test copy (`STEPOVER_APP`, `STEPOVER_BIN=none`, `STEPOVER_BUNDLE_ID=io.github.rudolphh.stepover.addcheck`), open it with a scratch `STEPOVER_HOME` under `~/Library/Caches`, `open -a <copy> "Tiny NSIS Game"`, and with `axdump` expect, in order, "Getting ready" or "Installing", then a "Tiny NSIS Game" tile with Play; then `open -a <copy> Empty` → "This folder doesn't have an installer or a game in it." with Try Again; `tiny.zip` → "Unpack it first, then drag in the folder."; the same folder twice → one tile.
- [ ] **Step 3:** Run `zsh app/build-app.sh` into a scratch path, then `app/Tests/ui/add-check.sh ~/Library/Caches/stepover-fixtures <games.json>`, `library-check.sh` and `couch-check.sh`. Expected: all pass (library 24/24, couch 12/12).
- [ ] **Step 4:** With the Live copy, drag `Tiny.Game...` from `~/Downloads` (copy it there first) and from a mounted disk image; record in the ledger whether macOS asked for access, and when (D5). If it asks mid-install, make `add` read the folder's listing at drop time so the question comes while the person is at the Mac, and check again.
- [ ] **Step 5: Commit** `"Add a game: drop folders onto Stepover and watch them install"`

### Task 10: Couch mode

**Files:**
- Modify: `app/Sources/StepoverApp/CouchView.swift`, `app/Sources/StepoverApp/Store.swift`, `app/Sources/StepoverApp/StepoverApp.swift`, `app/Tests/ui/couch-check.sh`

Behavior (D12, D13):
- Install tiles show in the row with art, verdict and `stage.text` at TV size; A and B follow `Couch.installAction`.
- Menu > Add a Game opens a list from `DownloadsScan.candidates(in: ~/Downloads)` with each item's recognized name, art and verdict; games already in the Library are marked; A calls `store.add`. Only when `UserDefaults` `downloadsAllowed` is set; otherwise the item reads "Allow Stepover to see your Downloads on the Mac first".
- At the Mac, View > Let Couch Mode See Downloads lists `~/Downloads` once (macOS asks then) and sets `downloadsAllowed` on success.
- When couch mode comes back after a game ends and `Afterwards.shouldOffer`, an on-screen prompt shows the Trash line: A Move to Trash, B Keep.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Extend `couch-check.sh`: with a waiting job in `installs.json` its tile reads "Waiting to install"; with a failed one, Return (A) re-queues it; with `downloadsAllowed` unset, Menu > Add a Game shows the Allow line; with it set and a Downloads stand-in (`STEPOVER_DOWNLOADS`, a new override in `Paths`, listed in how-it-works' Environment) holding `Tiny NSIS Game`, the list shows "Tiny NSIS Game".
- [ ] **Step 3:** Run `couch-check.sh`, `library-check.sh`, `add-check.sh`, `swift test`. Expected: all pass.
- [ ] **Step 4: Commit** `"Add a game: couch mode shows installs and adds games from Downloads"`

### Task 11: Docs, and the hands-on with the maintainer

**Files:**
- Modify: `docs/how-it-works.md` (a section "Adding games from an installer or folder": the pipeline, Appendix A's fix, the watcher's limits, installs.json, stepover-install.json, the personal folders), `README.md` (one line under features), `app/Sources/stepover/main.swift` usage text

- [ ] **Step 1:** Write the docs; run `swift test` and the three UI checks. Expected: all pass.
- [ ] **Step 2 (maintainer):** With one of the maintainer's real installer folders: drag it onto the Library window from the Mac (and another onto the Dock icon, or the same one after removing it); then from the couch, Menu > Add a Game. Record in the ledger: stages seen, whether the unarc large-address fix ran (log), time to Play, any macOS dialog, the game starting full size, and a first good run bringing the Trash offer.
- [ ] **Step 3:** D4's Red Dead check: an APFS clone of the RDR2 bottle (`cp -cR`) set to DPI 96, Red Dead started from it while the maintainer watches. Full size at 3456 by 2234: ledger "96 fits Red Dead". Not: add a `dpi` to `GraphicsPicker.Pick` for `rdr2.exe` and use it in `AddGame.makeBottle` after the game is found, with a test. Delete the clone afterwards.
- [ ] **Step 4: Commit** `"Add a game: docs"`
