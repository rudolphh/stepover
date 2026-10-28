# Library Screen Implementation Plan (Library plan B1 of B1, B2, C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stepover opens on a Library of the games you have: cover art, the two plain answers (will it play, does it work with a controller) and why, Play, with today's bottle pages one step away.

**Architecture:** Everything with rules goes in StepoverKit and is unit tested: which tiles exist (programs, installed Steam games, the Steam client), how they are matched to the games list and ordered, the short tile copy, the art cache and the hidden-games file. The app adds `LibraryView` (grid, detail panel, toolbar) and wires `Store` to the games list, art, the controller and the first-run runtime download. App code has no unit test target, so each UI task ends with a scripted accessibility check (the AX reader used for plan 2's Task 8) and the maintainer's look.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14), GameController framework, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-28-library-design.md` (What it is, G1, G2, G4, G6, The Library screen, Games appear by themselves, Constraints). Plan A (`2026-10-28-games-list.md`) provides `GamesList`, `GameIndex`, `Verdicts`.

**Left to plan B2:** the search field and "Can I play it?" cards, Install with Steam (automatic Steam setup), Add Game and dropping an installer, "Not this game?", Delete Game. **Plan C:** your own result.

## Global Constraints

- macOS 14 or later, logic in StepoverKit so it is unit tested, no new dependencies.
- No em dashes in UI copy. No "bottle", "runtime", "prefix" or "D3DMetal" on the Library screen or the detail panel; they live behind Settings and View > Bottles.
- A verdict informs, never prevents: every tile can Play.
- The maintainer's design rules: no colored rail on the left of a rounded card, no emoji as markers, a word with every color (never color alone), text contrast 4.5:1.
- Env-configurable endpoints, no API keys (art comes from Steam's CDN by app id).
- Mockup to follow: https://claude.ai/artifact/2yZnAsrwpR6jhV1CCwNhN7 (dark macOS window, 4-column grid of 2:3 covers, detail panel on the right).

## Review Focus

1. A Steam game also added as a program (a launcher made from its exe): one tile, not two. Test in Task 1.
2. A game with no list entry and no Steam id (a FitGirl install named "Sainthood"): a tile with its icon and "Not tested yet", no art request. Tests in Tasks 1 and 2.
3. No network on launch: the Library shows from the cached or bundled list and cached art; nothing waits on the network. Test in Task 2 (art never refetched once cached, a miss remembered).
4. A hidden game: gone from the grid, back with View > Show Hidden Games, and the choice survives a relaunch. Test in Task 1.
5. A first launch with no runtime: the Library still shows, the download starts by itself with progress in the toolbar, Play says why it waits, and a failed download says so with Retry instead of an alert. Checked in Task 4's scripted run (second scratch home, runtime list pointing at an unreachable download).

---

### Task 1: What the Library shows

**Files:**
- Create: `app/Sources/StepoverKit/Library.swift`
- Modify: `app/Sources/StepoverKit/SteamLibrary.swift` (add `client(in:)`)
- Test: `app/Tests/StepoverKitTests/LibraryTests.swift`

**Interfaces:**
- Consumes: `GameIndex`, `GameEntry`, `Verdicts`, `PlayVerdict.Kind`, `ControllerVerdict` (plan A); `Bottle`, `BottleConfig`, `Program`, `SteamApp`, `SteamLibrary`, `RecentGames.Entry` (existing).
- Produces:

```swift
public struct LibraryGame: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case program(Program), steamGame(SteamApp), steamClient(Program) }
    public var id: String               // "<bottle id>|<program name>", "<bottle id>|steam:<appid>", "<bottle id>|steam"
    public var name: String
    public var bottle: Bottle
    public var kind: Kind
    public var entry: GameEntry?        // the games list's entry, matched on the Mac
    public var lastPlayed: Date?
    public var steamAppID: Int?         // the Steam game's own id, else entry?.steam
    /// What Play runs: the program, or the Steam client with ["-applaunch", "<appid>"] named after the game.
    public var launch: Program
}
public enum Library {
    public static func games(bottles: [(bottle: Bottle, config: BottleConfig)], steamApps: (Bottle) -> [SteamApp],
                             index: GameIndex, recent: [RecentGames.Entry]) -> [LibraryGame]
}
public enum TileTone: Sendable { case good, maybe, caution, bad, mac, unknown }
extension PlayVerdict.Kind { public var short: String; public var tone: TileTone }
extension ControllerVerdict { public var short: String }
public struct LibraryState: Codable, Sendable {    // <root>/library.json
    public var hidden: [String]                     // LibraryGame ids
    public static var file: URL
    public static func load(from file: URL = file) -> LibraryState
    public func save(to file: URL = file) throws
}
extension SteamLibrary { public static func client(in bottle: Bottle) -> Program? }   // steam.exe as a Program named "Steam"
```

Rules for `games`: every program in each bottle's config is a tile, except that a program whose exe file is `steam.exe` is that bottle's `.steamClient` tile, and a program whose Windows exe path lies inside an installed Steam game's `windowsFolder` (case-insensitive) is folded into that Steam game's tile. Every `SteamLibrary.apps` game is a `.steamGame` tile. A bottle with Steam installed but no Steam program still gets a `.steamClient` tile from `SteamLibrary.client(in:)`. Matching: a Steam game by `index.entry(steam:)`, falling back to `index.match(name:exe:nil)`; a program by `index.match(name: program.name, exe: <exe file name>)`, then `index.match(name: bottle.name, exe: nil)`; the Steam client never. `lastPlayed`: the newest `RecentGames.Entry` with the same bottle name and program (or Steam game) name. Order: played games newest first, then the rest by name (case-insensitive); the Steam client tiles last.

`short` / `tone` (the tile line; the detail panel shows the full headline):

| Kind | short | tone |
|---|---|---|
| yourRuns | Runs on this Mac | good |
| yourProblems | Had problems on this Mac | caution |
| macVersion | There's a Mac version | mac |
| doesntRun | Doesn't run on Mac yet | bad |
| antiCheatBlocked | Won't run: anti-cheat | bad |
| singlePlayerOnly | Single-player only | caution |
| playsGreat | Plays great | good |
| playable | Playable | good |
| startsWithProblems | Starts, with problems | caution |
| shouldPlay | Should play | maybe |
| probablyWontRun | Probably won't run | bad |
| notTested | Not tested yet | unknown |

`ControllerVerdict.short`: yours "Played with a controller", full "Full controller", worksMenusMouse "Controller, mouse for menus", partial "Partial controller", keyboardMouse "Keyboard and mouse".

- [ ] **Step 1: Write the failing tests** (temp bottles as in `StepoverKitTests`; a fake Steam library is the `steamApps` closure; `index` from a two-entry `GamesList`)

```swift
func testProgramsSteamGamesAndTheClient() {
    // bottle "Steam": programs [Steam -> C:\Program Files (x86)\Steam\steam.exe, "RDR2 launcher" -> C:\...\steamapps\common\Red Dead Redemption 2\RDR2.exe]
    // steamApps: [SteamApp(id: 1174180, name: "Red Dead Redemption 2", windowsFolder: C:\...\common\Red Dead Redemption 2)]
    // bottle "Sainthood": program "Sainthood" -> C:\Games\Sainthood\Sainthood.exe
    let games = Library.games(bottles: bottles, steamApps: steamApps, index: index, recent: [])
    XCTAssertEqual(games.map(\.name), ["Red Dead Redemption 2", "Sainthood", "Steam"])
    XCTAssertEqual(games[0].steamAppID, 1174180)
    XCTAssertEqual(games[0].launch.args, ["-applaunch", "1174180"])
    XCTAssertEqual(games[0].launch.name, "Red Dead Redemption 2")
    XCTAssertNotNil(games[0].entry)
    XCTAssertNil(games[1].entry)          // nothing in the list is named Sainthood
    if case .steamClient = games[2].kind {} else { XCTFail() }
}
func testRecentlyPlayedFirst() { /* recent: Sainthood yesterday -> ["Sainthood", "Red Dead Redemption 2", "Steam"] */ }
func testMatchFallsBackToTheBottleName() { /* bottle "Hi-Fi RUSH", program "Launcher" (Launcher.exe), list entry "Hi-Fi RUSH" -> matched */ }
func testShortCopyAndTone() {
    XCTAssertEqual(PlayVerdict.Kind.antiCheatBlocked.short, "Won't run: anti-cheat")
    XCTAssertEqual(PlayVerdict.Kind.macVersion.tone, .mac)
    XCTAssertEqual(ControllerVerdict.worksMenusMouse.short, "Controller, mouse for menus")
}
func testHiddenGamesSurviveASave() throws {
    let file = dir.appendingPathComponent("library.json")
    XCTAssertEqual(LibraryState.load(from: file).hidden, [])
    try LibraryState(hidden: ["x|Steam"]).save(to: file)
    XCTAssertEqual(LibraryState.load(from: file).hidden, ["x|Steam"])
    try Data("{".utf8).write(to: file)
    XCTAssertEqual(LibraryState.load(from: file).hidden, [])
}
func testSteamClientFromTheInstallWhenNoProgram() { /* bottle with drive_c/Program Files (x86)/Steam/steam.exe, no programs -> one .steamClient tile; exe "C:\\Program Files (x86)\\Steam\\steam.exe" */ }
```

- [ ] **Step 2: Run `cd app && swift test --filter LibraryTests`.** Expected: compile failure, `Library` not defined.
- [ ] **Step 3: Implement `Library.swift` and `SteamLibrary.client(in:)`.**
- [ ] **Step 4: Run the tests, then `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `"Library: which games the Library shows, and their tile copy"`

### Task 2: Cover art

**Files:**
- Create: `app/Sources/StepoverKit/GameArt.swift`
- Test: `app/Tests/StepoverKitTests/GameArtTests.swift`

**Interfaces:**
- Produces:

```swift
public enum GameArt {
    public static let defaultBase = "https://cdn.cloudflare.steamstatic.com/steam/apps"
    public static var folder: URL                                           // <root>/Art
    public static func remoteURL(_ appID: Int, base: String = defaultBase) -> URL   // <base>/<id>/library_600x900.jpg
    public static func cached(_ appID: Int, in folder: URL = folder) -> URL?        // <folder>/<id>.jpg when present
    /// Downloads once: a cached file returns at once, a remembered miss (<id>.none) returns nil without a request.
    public static func fetch(_ appID: Int, into folder: URL = folder, base: String = defaultBase) async -> URL?
}
```

Only a 2xx answer whose body starts with the JPEG magic bytes (FF D8 FF) is kept; anything else writes `<id>.none` so the miss isn't retried every launch (a missing cover is normal for old games). 20 s timeout.

- [ ] **Step 1: Write the failing tests** using a `file://` base folder holding `<id>/library_600x900.jpg` (URLSession reads file URLs):

```swift
func testFetchCachesAndRemembersMisses() async throws {
    // base/1174180/library_600x900.jpg = FF D8 FF E0 ...; base/55230 missing
    let art = await GameArt.fetch(1174180, into: cache, base: base.absoluteString)
    XCTAssertEqual(art, cache.appendingPathComponent("1174180.jpg"))
    try FileManager.default.removeItem(at: base.appendingPathComponent("1174180"))    // offline now
    XCTAssertEqual(await GameArt.fetch(1174180, into: cache, base: base.absoluteString), art)
    XCTAssertNil(await GameArt.fetch(55230, into: cache, base: base.absoluteString))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("55230.none").path))
}
func testNotAJPEGIsAMiss() async throws { /* base/7/library_600x900.jpg = "<html>404</html>" -> nil, 7.none written */ }
func testRemoteURL() { XCTAssertEqual(GameArt.remoteURL(1174180).absoluteString, "https://cdn.cloudflare.steamstatic.com/steam/apps/1174180/library_600x900.jpg") }
```

- [ ] **Step 2: Run `swift test --filter GameArtTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `GameArt.swift`.**
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit** `"Library: cover art cache"`

### Task 3: Store wiring

**Files:**
- Modify: `app/Sources/StepoverApp/Store.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2; `GamesList.load/fetch/needsRefresh` (plan A).
- Produces (for Task 4):

```swift
// Store
@Published var library: [LibraryGame]          // rebuilt by reload() and when the games list arrives
@Published var hidden: Set<String>             // LibraryState
@Published var showHidden: Bool
@Published var showBottles: Bool              // @AppStorage-backed "showBottles", default false
@Published var art: [Int: NSImage]            // app id -> cover, filled as GameArt fetches land
@Published var controllerName: String?        // GameController: the first connected controller's vendorName
@Published var gamesCredits: [String]         // the list's credits
func playGame(_ game: LibraryGame)             // Launcher.run(game.launch, in: game.bottle) through work(...)
func setHidden(_ game: LibraryGame, _ hidden: Bool)
func openSettings(_ game: LibraryGame)          // showBottles = true, selection = game.bottle.id
```

At launch: `GamesList.load()` builds a `GameIndex`; when `GamesList.needsRefresh()`, fetch in the background and rebuild on success. Art: for each tile with a `steamAppID`, `GameArt.cached` at once, else `GameArt.fetch` in a detached task (at most 4 at a time), publishing into `art` as each lands. Controller: observe `.GCControllerDidConnect`/`.GCControllerDidDisconnect` and read `GCController.controllers().first?.vendorName`. First launch: when no runtime is installed and a `manifest` exists, start `installRuntime()` from `init` (the spec: the first download starts by itself). A failed first download sets `@Published var runtimeFailed: Bool` (and no alert); the toolbar offers Retry. (my call: the spec doesn't say what a failure looks like; an alert on launch is the opposite of frictionless)

- [ ] **Step 1:** Implement the members above.
- [ ] **Step 2: Build** `cd app && swift build --product StepoverApp`. Expected: builds. (No app test target: Task 4's scripted run checks the wiring.)
- [ ] **Step 3: Commit** `"Library: Store loads the games list, art and controller"`

### Task 4: The Library screen

**Files:**
- Create: `app/Sources/StepoverApp/LibraryView.swift`
- Modify: `app/Sources/StepoverApp/StepoverApp.swift` (root view, View and Help menus)

**Interfaces:**
- Consumes: Task 3's `Store` members; `Verdicts.play`, `Verdicts.controller`, `Kind.short/tone`, `ControllerVerdict.short`.

Layout (mockup): toolbar with the controller indicator ("8BitDo Pro 2 connected" / "No controller") and, while the first runtime downloads, "Getting ready to play: N%" (failed: "Couldn't get what games need" with Retry; a newer runtime: "A compatibility update is ready" with Download); a 4-column grid (adaptive, minimum 150 pt) of tiles: 2:3 art (cached art, else the program's icon on a tinted tile with the name), the name, the tone-colored short line with its word, the controller short line; hover or selection shows Play. A right detail panel (fixed 340 pt) for the selected tile: art, name, Play and Settings, "Will it play?" (headline, extra lines, reasons each with its source in secondary text), "Controller" (its full text). The Steam client tile reads "Steam" with "Your Steam games show up here" and Play opens Steam. Play while the runtime downloads is disabled with help text "Getting ready to play (N%)". Tile context menu: Play, Settings, Show in Finder, Hide from Library (or Show in Library when hidden). Empty Library: "No games yet" with New Bottle… and Import from CrossOver (B2 replaces it with search).

Menus: View > Library (⌘1) / Bottles (⌘2) switch `showBottles`; View > Show Hidden Games (toggle). Help > Games List Credits shows the list's `credits` in an alert. The window root shows `LibraryView` unless `showBottles`, where it shows today's `ContentView` (renamed `BottlesView`).

Tone colors on the dark and light window backgrounds (each paired with its word): good green, maybe blue, caution amber, bad red, mac violet, unknown secondary.

- [ ] **Step 1: Write the scripted check first** (`app/Tests/ui/library-check.sh`, run by hand, not by `swift test`): build a test copy (`STEPOVER_APP=<scratch>/Stepover Test.app STEPOVER_BIN=none STEPOVER_BUNDLE_ID=io.github.rudolphh.stepover.test`), make a scratch `STEPOVER_HOME` with APFS clones of the maintainer's bottles and runtime (`cp -cR`), point `STEPOVER_GAMES_LIST` at a local games.json, open it with `open -n --env …`, and read the window through the AX reader (`axdump <pid>`). It prints PASS/FAIL for: the window is the Library (no "Bottles" sidebar heading); each bottle's game name appears; "Red Dead Redemption 2" shows "Plays great" or "Runs on this Mac" and "Controller, mouse for menus"; "Sainthood" shows "Not tested yet"; the toolbar says "connected" or "No controller"; View > Bottles shows the "Bottles" heading again. A second scratch home with the bottle clones but no runtime, and `STEPOVER_RUNTIME_INDEX` pointing at a local index whose download is `https://127.0.0.1:9/x.tar.xz`: the game names still show, Play is disabled, and the toolbar reads "Couldn't get what games need" with Retry. Run it now. Expected: FAIL (no Library yet).
- [ ] **Step 2: Implement `LibraryView.swift` and the root/menu changes.**
- [ ] **Step 3: Run the scripted check.** Expected: every line PASS.
- [ ] **Step 4: Run `swift test` and `bash runtime/tests/run-tests.sh`.** Expected: all pass.
- [ ] **Step 5: Commit** `"Library: the games-first screen"`

### Task 5: Try it with the maintainer, and docs

**Files:**
- Modify: `docs/how-it-works.md` (a "Library" section), `README.md` (the first screenshot line, if it describes bottles first)

- [ ] **Step 1:** Open the test copy from Task 4 on the maintainer's screen; the maintainer looks at the grid, a tile's detail panel, Hide and View > Bottles. Fix what they find (each fix with its own failing Kit test, or a scripted-check line for UI).
- [ ] **Step 2:** Write the docs: what the Library shows and where each answer comes from (pointing at the Games list section), View > Bottles, hiding.
- [ ] **Step 3:** Remove the scratch home and the test app. Run both suites. Expected: all pass.
- [ ] **Step 4: Commit** `"Library: docs"`
