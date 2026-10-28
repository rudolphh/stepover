# Games List Implementation Plan (Library plan A of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daily-built list of games with Mac test results, anti-cheat, Steam and Steam Deck facts, plus the app code that downloads it, matches a program to a game on the Mac, and turns an entry into the two plain answers (will it play, does it work with a controller). No UI: plan B draws it.

**Architecture:** The list format and every rule live in StepoverKit, so the app and the builder share one `Codable` type. A new SwiftPM library `GamesListBuilder` (AppleGamingWiki and AreWeAntiCheatYet parsing, merging, network fetches) and executable `games-list` build `games.json`; a GitHub workflow runs it daily on macOS and uploads the file to a rolling release `games-list`. The app fetches that file like the runtime list (cache, keep the old copy on any failure) and ships a snapshot inside the app bundle.

**Left to plan B:** fetching the list at launch from `Store`, every screen, Help > Licenses showing `credits`, and the live Steam lookups (search, and installed Steam games the list lacks) that reuse Task 2's parsers.

**Tech Stack:** Swift 5.10 SwiftPM (no new dependencies), Foundation `URLSession`/`JSONDecoder`, XCTest, GitHub Actions (`macos-15`), `gh`.

**Spec:** `docs/superpowers/specs/2026-10-28-library-design.md` (sections Verdicts, Data, Matching non-Steam games, Constraints).

## Global Constraints

- macOS 14 or later, logic in StepoverKit so it is unit tested, no new dependencies.
- No em dashes in UI copy. Verdict copy is exactly the spec's (quoted in Task 4).
- Endpoints come from env vars with defaults: `STEPOVER_GAMES_LIST` (a URL or a file), like `STEPOVER_RUNTIME_INDEX`.
- No API keys anywhere.
- Steam's public endpoints are rate limited: the builder waits between Steam requests (`STEPOVER_GAMES_STEAM_DELAY`, default 1.5 s) and stops at a per-run budget (`STEPOVER_GAMES_STEAM_BUDGET`, default 1200 requests). The app makes no per-game requests in this plan.
- The list keeps AppleGamingWiki's license (CC BY-NC-SA 3.0) and credits AppleGamingWiki and AreWeAntiCheatYet (MIT) in its `credits` field.
- ProtonDB is left out: its data is ODbL (share-alike), which can't be combined with CC BY-NC-SA in one file. The spec allows leaving it out.
- `Paths.env` is read once (`static let`): tests pass locations as parameters, never `setenv`.
- Workflow actions are pinned by SHA like the existing workflows (`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`).

## Review Focus

1. A source fails during the daily run (AppleGamingWiki API error, AreWeAntiCheatYet 404, Steam answering 429): that source's data comes from the previous list, and a list that shrank by more than 10% is never published. Tests in Task 6.
2. Steam has no data for a game (`"success": false`, removed or region-locked): the entry stays, without Steam facts; nothing crashes. Test in Task 2.
3. AppleGamingWiki's hand-typed fields: ratings with odd case, spaces or a `<ref>` stuck to them, Refdevice dates in several formats or missing, method strings with build numbers. Test in Task 5.
4. Two games share a normalized name (a remake and the original): no match rather than the wrong game. Test in Task 3.
5. A first launch with no network and no bundled list (a dev build): an empty list, "Not tested yet" for everything, no crash. Tests in Tasks 1 and 4.

---

## File Structure

- `app/Sources/StepoverKit/GamesList.swift` (create): the list format, decode, load, fetch, cache, bundled snapshot.
- `app/Sources/StepoverKit/SteamStore.swift` (create): Steam `appdetails` and Steam Deck report parsing (plan B reuses it for search).
- `app/Sources/StepoverKit/GameMatch.swift` (create): name normalization and `GameIndex` lookups.
- `app/Sources/StepoverKit/Verdicts.swift` (create): the will-it-play and controller rules.
- `app/Sources/GamesListBuilder/AppleGamingWiki.swift`, `AntiCheatList.swift`, `Merge.swift`, `Fetch.swift` (create).
- `app/Sources/games-list/main.swift` (create): the builder command.
- `app/Package.swift` (modify): the two new targets and `GamesListBuilderTests`.
- `app/Tests/StepoverKitTests/GamesListTests.swift`, `SteamStoreTests.swift`, `GameMatchTests.swift`, `VerdictTests.swift` (create).
- `app/Tests/GamesListBuilderTests/AppleGamingWikiTests.swift`, `MergeTests.swift` (create).
- `.github/workflows/games-list.yml` (create), `runtime/tests/test-games-workflow.sh` (create).
- `app/build-app.sh`, `release/make-release.sh` (modify): bundle the snapshot.
- `docs/how-it-works.md` (modify): a Games list section.

---

### Task 1: The list format, loader and cache

**Files:**
- Create: `app/Sources/StepoverKit/GamesList.swift`
- Test: `app/Tests/StepoverKitTests/GamesListTests.swift`

**Interfaces:**
- Produces (every later task uses these exact names):

```swift
public struct GamesList: Codable, Sendable {
    public static let supportedFormat = 1
    public var format: Int
    public var generated: String          // ISO 8601, when CI built it
    public var credits: [String]          // attribution lines (license obligations)
    public var games: [GameEntry]
}
public struct GameEntry: Codable, Hashable, Sendable {
    public var id: String                 // "steam:<appid>", else "agw:<page title>", else "acy:<slug>"
    public var name: String
    public var names: [String]            // other names it goes by, for matching; [] when none
    public var steam: Int?
    public var epic: String?              // "<namespace>/<slug>" from AreWeAntiCheatYet
    public var exes: [String]             // exe file names from Stepover's fix list
    public var agwPage: String?
    public var mac: MacTests?
    public var antiCheat: AntiCheat?
    public var store: StoreFacts?         // Steam store facts
    public var deck: DeckFacts?
    public var fix: Bool                  // Stepover's fix list has a fix for it
}
public enum MacRating: String, Codable, Sendable, Comparable { case unplayable, runs, playable, perfect } // worst to best
public struct MacTest: Codable, Hashable, Sendable { public var rating: MacRating; public var device: String?; public var method: String?; public var date: String? } // date "2025-05-05" or "2025-05"
public struct MacTests: Codable, Hashable, Sendable { public var native: MacTest?; public var rosetta: MacTest?; public var crossover: MacTest?; public var wine: MacTest? }
public struct AntiCheat: Codable, Hashable, Sendable { public var names: [String]; public var status: String }
public enum ControllerCategory: String, Codable, Sendable { case full, partial }
public struct StoreFacts: Codable, Hashable, Sendable { public var macVersion: Bool; public var singlePlayer: Bool; public var controller: ControllerCategory?; public var checked: String } // checked "2026-10-28"
public enum DeckCategory: Int, Codable, Sendable { case unknown = 0, unsupported, playable, verified }
public struct DeckFacts: Codable, Hashable, Sendable { public var category: DeckCategory; public var controllerWorks: Bool; public var checked: String }

extension GamesList {
    public static func decode(_ data: Data) -> GamesList?
    public static var cacheFile: URL                                  // <root>/games-list.json
    public static func defaultSource(repository: String) -> String   // .../releases/download/games-list/games.json
    public static var source: String                                  // STEPOVER_GAMES_LIST, else defaultSource(Paths.sourceRepository)
    public static func bundled(bundle: Bundle? = Paths.appBundle) -> GamesList?   // Resources/games.json
    public static func load(cache: URL = cacheFile, bundled: GamesList? = bundled()) -> GamesList   // never fails: empty list last
    public static func needsRefresh(cache: URL = cacheFile, now: Date = Date()) -> Bool             // missing or older than 24 h
    @discardableResult public static func fetch(from source: String = source, to cache: URL = cacheFile) async -> Bool
}
```

Every type above has a public memberwise `init` (the builder, another module, creates them), and `MacRating`'s `<` follows the declaration order.

`decode` returns nil for anything that isn't JSON of this shape, for `format` greater than `supportedFormat`, and for an empty `games`. `load` order: a decodable cache, else `bundled`, else `GamesList(format: 1, generated: "", credits: [], games: [])`. `fetch` mirrors `RuntimeIndex.fetch` (local file or URL, 20 s timeout, 2xx only, writes atomically only what `decode` accepts, never throws).

- [ ] **Step 1: Write the failing tests** (`GamesListTests`, a temp `dir` per test as in `RuntimeIndexTests`; a helper `json(format:games:)` writes a list with one RDR2 entry)

```swift
func testDecodesFormat1() {
    let list = GamesList.decode(json(format: 1))
    XCTAssertEqual(list?.games.first?.steam, 1174180)
    XCTAssertEqual(list?.games.first?.mac?.crossover?.rating, .perfect)
    XCTAssertEqual(list?.games.first?.deck?.category, .playable)
}
func testRejectsNewerFormatGarbageAndEmpty() {
    XCTAssertNil(GamesList.decode(json(format: 2)))
    XCTAssertNil(GamesList.decode(Data("<html>rate limited</html>".utf8)))
    XCTAssertNil(GamesList.decode(json(format: 1, games: [])))
}
func testLoadFallsBackToBundledThenEmpty() throws {
    let cache = dir.appendingPathComponent("games-list.json")
    let bundled = GamesList.decode(json(format: 1))!
    XCTAssertEqual(GamesList.load(cache: cache, bundled: bundled).games.count, 1)
    try Data("broken".utf8).write(to: cache)
    XCTAssertEqual(GamesList.load(cache: cache, bundled: bundled).games.count, 1)
    XCTAssertTrue(GamesList.load(cache: cache, bundled: nil).games.isEmpty)
}
func testFetchKeepsCacheOnBadDataAndWritesGoodData() async throws { /* as RuntimeIndexTests: bad local file -> false, cache bytes unchanged; good file -> true, cache decodes */ }
func testNeedsRefresh() throws {
    let cache = dir.appendingPathComponent("games-list.json")
    XCTAssertTrue(GamesList.needsRefresh(cache: cache))
    try json(format: 1).write(to: cache)
    XCTAssertFalse(GamesList.needsRefresh(cache: cache, now: Date().addingTimeInterval(3600)))
    XCTAssertTrue(GamesList.needsRefresh(cache: cache, now: Date().addingTimeInterval(25 * 3600)))
}
func testDefaultSource() {
    XCTAssertEqual(GamesList.defaultSource(repository: "rudolphh/stepover"),
                   "https://github.com/rudolphh/stepover/releases/download/games-list/games.json")
}
func testBundledReadsResources() throws { /* a temp folder Foo.app/Contents/Resources/games.json; Bundle(url:) of Foo.app -> bundled(bundle:) has 1 game; a bundle without the file -> nil */ }
```

- [ ] **Step 2: Run, expect a compile failure** (`GamesList` not defined): `cd app && swift test --filter GamesListTests`
- [ ] **Step 3: Implement `GamesList.swift`** with the types and functions above. The cache's age for `needsRefresh` is the file's modification date.
- [ ] **Step 4: Run `swift test --filter GamesListTests`.** Expected: all pass.
- [ ] **Step 5: Commit** `git add app/Sources/StepoverKit/GamesList.swift app/Tests/StepoverKitTests/GamesListTests.swift && git commit -m "Games list: format, loader and cache"`

### Task 2: Steam store and Steam Deck facts

**Files:**
- Create: `app/Sources/StepoverKit/SteamStore.swift`
- Test: `app/Tests/StepoverKitTests/SteamStoreTests.swift`

**Interfaces:**
- Consumes: `StoreFacts`, `DeckFacts`, `ControllerCategory`, `DeckCategory` (Task 1).
- Produces:

```swift
public enum SteamStore {
    public static func appdetailsURL(_ appID: Int) -> URL   // https://store.steampowered.com/api/appdetails?appids=<id>&cc=us&l=en
    public static func deckReportURL(_ appID: Int) -> URL   // https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=<id>&l=english
    /// nil when Steam has no data ("success": false) or the body isn't appdetails.
    public static func storeFacts(appdetails: Data, appID: Int, checked: String) -> (name: String, facts: StoreFacts)?
    public static func deckFacts(report: Data, checked: String) -> DeckFacts?
}
```

Category ids (verified 2026-10-28): 2 Single-player, 28 Full controller support, 18 Partial Controller Support (28 wins when both appear). Mac version: `platforms.mac`. Deck: `results.resolved_category` (0 to 3); the controller works when `results.resolved_items` has `loc_token` `#SteamDeckVerified_TestResult_DefaultControllerConfigFullyFunctional` with `display_type` 4.

- [ ] **Step 1: Write the failing tests** with inline JSON trimmed from real responses:

```swift
func testStoreFactsRDR2() {   // categories 2, 1, 18; platforms mac false
    let r = SteamStore.storeFacts(appdetails: rdr2, appID: 1174180, checked: "2026-10-28")
    XCTAssertEqual(r?.name, "Red Dead Redemption 2")
    XCTAssertEqual(r?.facts, StoreFacts(macVersion: false, singlePlayer: true, controller: .partial, checked: "2026-10-28"))
}
func testStoreFactsFullControllerWinsAndMacVersion() { /* categories 2, 28, 18; mac true -> .full, macVersion true */ }
func testStoreFactsNoData() {
    XCTAssertNil(SteamStore.storeFacts(appdetails: Data(#"{"1":{"success":false}}"#.utf8), appID: 1, checked: "2026-10-28"))
    XCTAssertNil(SteamStore.storeFacts(appdetails: Data("<html>".utf8), appID: 1, checked: "2026-10-28"))
}
func testDeckFacts() {   // RDR2's real report: category 2, controller token display_type 4
    XCTAssertEqual(SteamStore.deckFacts(report: rdr2Deck, checked: "2026-10-28"),
                   DeckFacts(category: .playable, controllerWorks: true, checked: "2026-10-28"))
    // same token with display_type 3 (a warning), category 1
    XCTAssertEqual(SteamStore.deckFacts(report: unsupportedDeck, checked: "2026-10-28")?.controllerWorks, false)
}
```

- [ ] **Step 2: Run `swift test --filter SteamStoreTests`.** Expected: compile failure, `SteamStore` not defined.
- [ ] **Step 3: Implement `SteamStore.swift`** with `JSONSerialization` (the bodies are loosely typed).
- [ ] **Step 4: Run it again.** Expected: pass.
- [ ] **Step 5: Commit** `"Games list: Steam store and Steam Deck facts"`

### Task 3: Matching a program to a game, on the Mac

**Files:**
- Create: `app/Sources/StepoverKit/GameMatch.swift`
- Test: `app/Tests/StepoverKitTests/GameMatchTests.swift`

**Interfaces:**
- Consumes: `GamesList`, `GameEntry` (Task 1).
- Produces:

```swift
public enum GameName { public static func normalized(_ name: String) -> String }
public struct GameIndex: Sendable {
    public init(_ list: GamesList)
    public func entry(steam appID: Int) -> GameEntry?
    /// The one entry whose exe names include `exe` (file name, any case), else the one entry whose name or
    /// other names normalize to `name`'s; nil when none or more than one fits.
    public func match(name: String, exe: String?) -> GameEntry?
}
```

`normalized`: fold case and diacritics; drop ™ ® ©; `&` becomes `and`; every run of characters that aren't letters or digits becomes one space; trim; then drop one trailing edition phrase from: `game of the year edition`, `goty edition`, `goty`, `definitive edition`, `complete edition`, `ultimate edition`, `deluxe edition`, `enhanced edition`, `anniversary edition`. (my call: exact match after this, nothing fuzzier, per the spec's anti-goal "a confident badge that's wrong")

- [ ] **Step 1: Write the failing tests**

```swift
func testNormalized() {
    XCTAssertEqual(GameName.normalized("Hi-Fi RUSH"), "hi fi rush")
    XCTAssertEqual(GameName.normalized("Apex Legends™"), "apex legends")
    XCTAssertEqual(GameName.normalized("The Witcher 3: Wild Hunt – Game of the Year Edition"), "the witcher 3 wild hunt")
    XCTAssertEqual(GameName.normalized("Pokémon & Friends"), "pokemon and friends")
}
func testMatchByExeThenName() {
    let index = GameIndex(list([entry("steam:1174180", "Red Dead Redemption 2", exes: ["RDR2.exe"]),
                                entry("steam:1817230", "Hi-Fi RUSH", names: ["HI-Fi RUSH"])]))
    XCTAssertEqual(index.match(name: "RDR2", exe: "rdr2.EXE")?.steam, 1174180)
    XCTAssertEqual(index.match(name: "Hi-Fi Rush", exe: "Launcher.exe")?.steam, 1817230)
    XCTAssertEqual(index.entry(steam: 1817230)?.name, "Hi-Fi RUSH")
}
func testNoMatchRatherThanWrongGame() {
    let index = GameIndex(list([entry("steam:55230", "Saints Row: The Third"),
                                entry("steam:2050650", "Resident Evil 4"), entry("steam:254700", "Resident Evil 4", names: [])]))
    XCTAssertNil(index.match(name: "Sainthood", exe: "Sainthood.exe"))
    XCTAssertNil(index.match(name: "Resident Evil 4", exe: nil))   // two games share the name
}
```

- [ ] **Step 2: Run `swift test --filter GameMatchTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `GameMatch.swift`.** `GameIndex` builds dictionaries once (steam id, lowercased exe, normalized name to entry ids) and treats a key with two different entries as ambiguous.
- [ ] **Step 4: Run it again.** Expected: pass.
- [ ] **Step 5: Commit** `"Games list: match programs to games on the Mac"`

### Task 4: The verdicts

**Files:**
- Create: `app/Sources/StepoverKit/Verdicts.swift`
- Test: `app/Tests/StepoverKitTests/VerdictTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces:

```swift
public enum PlayResult: Equatable, Sendable { case runs(minutes: Int), problems }   // plan C records it
public struct Reason: Equatable, Sendable { public var text: String; public var source: String? }
public struct PlayVerdict: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case yourRuns, yourProblems, macVersion, doesntRun, antiCheatBlocked,
                                            singlePlayerOnly, playsGreat, playable, startsWithProblems, shouldPlay, probablyWontRun, notTested }
    public var kind: Kind
    public var headline: String
    public var extra: [String]      // added lines, in this order: the single-player line, the fix line
    public var reasons: [Reason]    // every fact behind it, whatever the headline
}
public enum ControllerVerdict: String, Sendable {
    case yours = "Played with a controller on this Mac", full = "Full controller support",
         worksMenusMouse = "Controller works; some menus may need a mouse", partial = "Partial controller support",
         keyboardMouse = "Keyboard and mouse"
}
public enum Verdicts {
    public static let d3dmetalSince = "2023-06"   // Mac tests dated before this predate Apple's D3DMetal
    public static func play(_ entry: GameEntry?, yourResult: PlayResult? = nil) -> PlayVerdict
    public static func controller(_ entry: GameEntry?, playedWithController: Bool = false) -> ControllerVerdict?
}
```

**`play` rules, first match wins** (headline copy is the spec's, exactly):

1. `yourResult`: `.runs(m)`: "Runs on this Mac (you played N h)" with N = m / 60 when m >= 60, else "Runs on this Mac (you played M min)"; `.problems`: "Had problems on this Mac".
2. `store.macVersion` and `mac.native?.rating != .unplayable`: "There's a Mac version", or "There's a Mac version (not checked on current macOS)" when `mac.native` is nil. (`.unplayable` skips this rule.)
3. Let `cx`, `wn` be `mac.crossover`, `mac.wine`. Both `.unplayable`, or one `.unplayable` and the other nil: "Doesn't run on Mac yet". Exception: when every such unplayable test's `date` is before `d3dmetalSince` and `deck.category` is `.verified` or `.playable`, skip this rule.
4. `antiCheat != nil`: if the better of `cx`/`wn` is `.perfect` or `.playable`, use rule 5's headline and add extra "Single-player only: online play needs anti-cheat that doesn't work on Mac"; else with `store?.singlePlayer == true` the headline is that same line (kind `.singlePlayerOnly`); else "Won't run: needs anti-cheat that doesn't work on Mac" (`.antiCheatBlocked`).
5. The better of `cx`/`wn`: `.perfect` "Plays great (tested on Mac)", `.playable` "Playable (tested on Mac)", `.runs` "Starts, with problems (tested on Mac)".
6. `deck.category` `.verified`/`.playable`: "Should play (works on Steam Deck, not tested on Mac yet)"; `.unsupported`: "Probably won't run".
7. Otherwise, and for a nil entry: "Not tested yet. Try it; Stepover will remember how it went."

Every verdict with `entry.fix` adds extra "Stepover applies a fix for this game automatically".

**Reasons**, in this order, whenever the fact exists:
- Each of `crossover`, `wine`: "Tested with <method> on <device>: <word>." where `<method>` is the test's `method` else "CrossOver"/"Wine", and " on <device>" is left out without a device; `<word>`: perfect, playable, "starts, with problems", "doesn't run". An unplayable test dated before `d3dmetalSince` instead reads "An older Mac test (<year>) didn't run." Source: "AppleGamingWiki", plus ", <Mon> <year>" when the date has a month ("AppleGamingWiki, May 2025"). (my call: "Tested with … on …" instead of the spec's "Tested on a … with …", because device names don't all take "a")
- `store.macVersion`: "Steam sells a native Mac version." (source "Steam"); native `.unplayable`: "The old Mac version doesn't run on current macOS." ("AppleGamingWiki").
- `antiCheat`: "Uses <names joined with RuntimeCatalog.joined>, which doesn't work on Mac." ("AreWeAntiCheatYet").
- `deck` other than unknown: "Steam Deck: Verified." / "Steam Deck: Playable." / "Steam Deck: Unsupported." ("Valve").

There is no "No anti-cheat" reason: a game missing from AreWeAntiCheatYet isn't proof (anti-goal: a confident badge that's wrong).

**`controller`**: `playedWithController` gives `.yours`; `store.controller == .full` gives `.full`; `.partial` with `deck.controllerWorks` gives `.worksMenusMouse`; `.partial` alone gives `.partial`; store facts without a controller category give `.keyboardMouse`; no store facts give nil.

- [ ] **Step 1: Write the failing tests**, one per rule, using the real data the mockup used (the helper `game(...)` builds an entry):

```swift
func testYourResultWins() {
    XCTAssertEqual(Verdicts.play(rdr2, yourResult: .runs(minutes: 130)).headline, "Runs on this Mac (you played 2 h)")
    XCTAssertEqual(Verdicts.play(rdr2, yourResult: .runs(minutes: 40)).headline, "Runs on this Mac (you played 40 min)")
    XCTAssertEqual(Verdicts.play(rdr2, yourResult: .problems).kind, .yourProblems)
}
func testMacVersion() {   // Cyberpunk: mac true, native perfect; Duckov: mac true, no AGW; an old 32-bit game: native unplayable
    XCTAssertEqual(Verdicts.play(cyberpunk).headline, "There's a Mac version")
    XCTAssertEqual(Verdicts.play(duckov).headline, "There's a Mac version (not checked on current macOS)")
    XCTAssertNotEqual(Verdicts.play(old32bit).kind, .macVersion)
    XCTAssertTrue(Verdicts.play(old32bit).reasons.contains(Reason(text: "The old Mac version doesn't run on current macOS.", source: "AppleGamingWiki")))
}
func testDoesntRunAndTheOldTestException() {
    XCTAssertEqual(Verdicts.play(game(crossover: .unplayable)).headline, "Doesn't run on Mac yet")
    let old = game(crossover: test(.unplayable, date: "2022-05-31"), deck: .verified)
    XCTAssertEqual(Verdicts.play(old).headline, "Should play (works on Steam Deck, not tested on Mac yet)")
    XCTAssertEqual(Verdicts.play(old).reasons.first?.text, "An older Mac test (2022) didn't run.")
}
func testAntiCheat() {   // Elden Ring: EAC, wine perfect, single-player; Apex: EAC+Hyperion, crossover unplayable, no single-player; Valorant: no Steam data
    XCTAssertEqual(Verdicts.play(eldenRing).headline, "Plays great (tested on Mac)")
    XCTAssertEqual(Verdicts.play(eldenRing).extra.first, "Single-player only: online play needs anti-cheat that doesn't work on Mac")
    XCTAssertEqual(Verdicts.play(apex).headline, "Doesn't run on Mac yet")      // rule 3 comes first
    XCTAssertEqual(Verdicts.play(valorant).headline, "Won't run: needs anti-cheat that doesn't work on Mac")
    XCTAssertEqual(Verdicts.play(singlePlayerWithAntiCheat).kind, .singlePlayerOnly)
}
func testTestedOnMacAndReasons() {   // RDR2: crossover perfect (MacBook Air M3, Crossover 25.0, 2025-05-05), wine unplayable (no date), deck playable, fix
    let v = Verdicts.play(rdr2)
    XCTAssertEqual(v.headline, "Plays great (tested on Mac)")
    XCTAssertEqual(v.reasons.first, Reason(text: "Tested with Crossover 25.0 on MacBook Air M3: perfect.", source: "AppleGamingWiki, May 2025"))
    XCTAssertTrue(v.reasons.contains(Reason(text: "Steam Deck: Playable.", source: "Valve")))
    XCTAssertEqual(v.extra, ["Stepover applies a fix for this game automatically"])
}
func testLinuxEvidenceAndNothing() {
    XCTAssertEqual(Verdicts.play(game(deck: .unsupported)).headline, "Probably won't run")
    XCTAssertEqual(Verdicts.play(nil).headline, "Not tested yet. Try it; Stepover will remember how it went.")
}
func testController() {
    XCTAssertEqual(Verdicts.controller(rdr2), .worksMenusMouse)
    XCTAssertEqual(Verdicts.controller(eldenRing), .full)
    XCTAssertEqual(Verdicts.controller(duckov), .keyboardMouse)
    XCTAssertNil(Verdicts.controller(valorant))
    XCTAssertEqual(Verdicts.controller(duckov, playedWithController: true), .yours)
}
```

- [ ] **Step 2: Run `swift test --filter VerdictTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `Verdicts.swift`.** Month names for the source: `DateFormatter` with `en_US_POSIX`, "MMM yyyy".
- [ ] **Step 4: Run it, then the whole suite (`swift test`).** Expected: all pass.
- [ ] **Step 5: Commit** `"Games list: will-it-play and controller verdicts"`

### Task 5: Reading AppleGamingWiki and AreWeAntiCheatYet

**Files:**
- Modify: `app/Package.swift` (add `.target(name: "GamesListBuilder", dependencies: ["StepoverKit"])`, `.executableTarget(name: "games-list", dependencies: ["GamesListBuilder"])`, `.testTarget(name: "GamesListBuilderTests", dependencies: ["GamesListBuilder"])`)
- Create: `app/Sources/GamesListBuilder/AppleGamingWiki.swift`, `app/Sources/GamesListBuilder/AntiCheatList.swift`
- Test: `app/Tests/GamesListBuilderTests/AppleGamingWikiTests.swift`

**Interfaces:**
- Consumes: `MacTests`, `MacTest`, `MacRating` (Task 1).
- Produces:

```swift
public struct AGWPage: Equatable, Sendable { public var title: String; public var steam: Int?; public var tests: MacTests }
public enum AppleGamingWiki {
    public static func parse(title: String, wikitext: String) -> AGWPage?   // nil when the page has no Compatibility/macOS block
    public static func date(_ text: String) -> String?                     // "2025-05-05", "2025-05" or nil
    public static func method(_ text: String) -> String                    // "Crossover 25.0 (25.0.0.38553)" -> "Crossover 25.0"
}
public struct AntiCheatGame: Equatable, Sendable { public var name: String; public var slug: String; public var status: String; public var anticheats: [String]; public var steam: Int?; public var epic: String? }
public enum AntiCheatList { public static func decode(_ data: Data) -> [AntiCheatGame]? }   // nil when not the games.json array
```

`parse`: `steam` from the Infobox line `|steam appid = <digits>` (the first number). Ratings from the `{{Compatibility/macOS` block's lines `|native =`, `|rosetta 2 =`, `|crossover =`, `|wine =`: the first word, lowercased, kept only when it is perfect, playable, runs or unplayable. Each tested method's `device`, `method` and `date` come from the first `{{Refdevice|…}}` on its `|<method> notes =` line (fields `key=value` split on `|`, trimmed). AreWeAntiCheatYet's `storeIds.steam` is a string; `epic` is `"<namespace>/<slug>"`.

- [ ] **Step 1: Write the failing tests** with a trimmed copy of the real RDR2 and Elden Ring wikitext:

```swift
func testParseRDR2() {
    let page = AppleGamingWiki.parse(title: "Red Dead Redemption 2", wikitext: rdr2Wikitext)
    XCTAssertEqual(page?.steam, 1174180)
    XCTAssertEqual(page?.tests.crossover, MacTest(rating: .perfect, device: "MacBook Air M3 8GB 8core CPU 8core GPU", method: "Crossover 25.0", date: "2025-05-05"))
    XCTAssertEqual(page?.tests.wine?.rating, .unplayable)
    XCTAssertNil(page?.tests.native)                       // "na"
}
func testMessyFields() {
    XCTAssertEqual(AppleGamingWiki.parse(title: "X", wikitext: "{{Compatibility/macOS\n|crossover = Perfect <ref>x</ref>\n|wine= unknown\n}}")?.tests.crossover?.rating, .perfect)
    XCTAssertNil(AppleGamingWiki.parse(title: "X", wikitext: "{{Infobox game\n|steam appid = 1\n}}"))
    XCTAssertEqual(AppleGamingWiki.date("May 5th, 2025"), "2025-05-05")
    XCTAssertEqual(AppleGamingWiki.date("2025-05-12"), "2025-05-12")
    XCTAssertEqual(AppleGamingWiki.date("12 March 2024"), "2024-03-12")
    XCTAssertEqual(AppleGamingWiki.date("June 2023"), "2023-06")
    XCTAssertNil(AppleGamingWiki.date("last week"))
    XCTAssertEqual(AppleGamingWiki.method(" Crossover 25.0 (25.0.0.38553)"), "Crossover 25.0")
}
func testAntiCheatDecode() {   // two real entries: Fortnite (epic only) and Apex (steam "1172470")
    let games = AntiCheatList.decode(acyJSON)
    XCTAssertEqual(games?.first { $0.slug == "fortnite" }?.epic, "fn/fortnite")
    XCTAssertEqual(games?.first { $0.steam == 1172470 }?.anticheats, ["Easy Anti-Cheat", "Hyperion"])
    XCTAssertNil(AntiCheatList.decode(Data("404: Not Found".utf8)))
}
```

- [ ] **Step 2: Run `swift test --filter GamesListBuilderTests`.** Expected: compile failure.
- [ ] **Step 3: Implement both files.**
- [ ] **Step 4: Run it again, then `swift build --product StepoverApp`** (the new targets must not disturb the app). Expected: pass, build ok.
- [ ] **Step 5: Commit** `"Games list builder: AppleGamingWiki and AreWeAntiCheatYet"`

### Task 6: Merging, refreshing and the builder command

**Files:**
- Create: `app/Sources/GamesListBuilder/Merge.swift`, `app/Sources/GamesListBuilder/Fetch.swift`, `app/Sources/games-list/main.swift`
- Test: `app/Tests/GamesListBuilderTests/MergeTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2 and 5; `Fix` (existing, `match.steam`, `match.exe`, `name`).
- Produces:

```swift
public struct BuildSources: Sendable {
    public var agw: [AGWPage]?             // nil: the source failed this run
    public var antiCheat: [AntiCheatGame]?
    public var fixes: [Fix]
    public var mostPlayed: [Int]?          // Steam app ids
    public init(agw: [AGWPage]?, antiCheat: [AntiCheatGame]?, fixes: [Fix], mostPlayed: [Int]?)
}
public enum Merge {
    /// One entry per game. A failed source's fields come from `previous`; Steam and Deck facts always do (refresh() replaces them).
    public static func entries(_ sources: BuildSources, previous: GamesList?) -> [GameEntry]
    /// Steam app ids whose store facts are missing or older than `maxAge` days, never-checked first, then oldest.
    public static func steamToRefresh(_ entries: [GameEntry], today: String, maxAge: Int = 7, limit: Int) -> [Int]
    public static let minimumFirstList = 500
    /// Throws when the new list has fewer than 90% of the previous list's games, or fewer than minimumFirstList with no previous list.
    public static func check(_ new: GamesList, previous: GamesList?) throws
}
public enum Fetch {   // network only; each waits `delay` between requests and sends User-Agent "Stepover games list (https://github.com/<repo>)"
    public static func appleGamingWiki() async throws -> [AGWPage]          // embeddedin Template:Compatibility/macOS, then revisions 50 titles at a time
    public static func antiCheat() async throws -> [AntiCheatGame]         // https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json
    public static func mostPlayed() async throws -> [Int]                    // https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/
    /// Fills store and deck facts for `ids`; stops early (keeping what it has) on HTTP 429/403 or when `budget` requests are spent.
    public static func steam(_ ids: [Int], into entries: inout [GameEntry], today: String, budget: Int, delay: TimeInterval) async
}
```

Entry identity: the Steam app id when known (from AppleGamingWiki, AreWeAntiCheatYet, the fix list or the charts), else the AppleGamingWiki title, else the AreWeAntiCheatYet slug; `id` follows (`steam:…`, `agw:…`, `acy:…`). `name`: the Steam name when store facts exist, else the AppleGamingWiki title, else AreWeAntiCheatYet's name, else the fix's name; every other name goes into `names` (deduplicated by `GameName.normalized`). `exes` and `fix` come from the fix list. Entries are sorted by `id` so the file diffs cleanly.

`games-list verify <file>` decodes a file with `GamesList.decode` and prints `ok: <count> games`, or `not a games list` with exit 1. `games-list build --fixes <dir> --out <file> [--previous <file>]` reads every `*.json` under `<dir>/games` and `<dir>/proton` as `Fix`, fetches the four sources (a failure becomes nil and prints `<source> failed: <error>; keeping the previous data`), merges, refreshes Steam facts for `steamToRefresh(limit: budget / 2)` ids (two requests each), runs `check`, and writes `GamesList(format: 1, generated: <now ISO 8601>, credits: [<AppleGamingWiki line>, <AreWeAntiCheatYet line>], games:)` with sorted keys. Credits:
- "Mac test results from AppleGamingWiki (applegamingwiki.com), CC BY-NC-SA 3.0."
- "Anti-cheat data from AreWeAntiCheatYet (areweanticheatyet.com), MIT License."

- [ ] **Step 1: Write the failing tests**

```swift
func testMergeJoinsSourcesBySteamID() {   // AGW RDR2 (1174180), fix "Red Dead Redemption 2" steam 1174180 exe RDR2.exe, ACY Fortnite (epic only)
    let games = Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [fortnite], fixes: [rdr2Fix], mostPlayed: [730]), previous: nil)
    let rdr2 = games.first { $0.steam == 1174180 }
    XCTAssertEqual(rdr2?.id, "steam:1174180"); XCTAssertEqual(rdr2?.exes, ["RDR2.exe"]); XCTAssertEqual(rdr2?.fix, true)
    XCTAssertEqual(rdr2?.mac?.crossover?.rating, .perfect)
    XCTAssertEqual(games.first { $0.epic == "fn/fortnite" }?.id, "acy:fortnite")
    XCTAssertNotNil(games.first { $0.id == "steam:730" })
}
func testFailedSourceKeepsPreviousData() {
    let previous = GamesList(format: 1, generated: "", credits: [], games: Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [apex], fixes: [], mostPlayed: nil), previous: nil))
    let games = Merge.entries(BuildSources(agw: nil, antiCheat: nil, fixes: [], mostPlayed: nil), previous: previous)
    XCTAssertEqual(games.first { $0.steam == 1174180 }?.mac?.crossover?.rating, .perfect)
    XCTAssertEqual(games.first { $0.steam == 1172470 }?.antiCheat?.names, ["Easy Anti-Cheat", "Hyperion"])
}
func testSteamToRefresh() {   // never checked, checked 2026-10-01, checked 2026-10-27; today 2026-10-28
    XCTAssertEqual(Merge.steamToRefresh(threeEntries, today: "2026-10-28", limit: 10), [3, 1])
    XCTAssertEqual(Merge.steamToRefresh(threeEntries, today: "2026-10-28", limit: 1), [3])
}
func testCheckRefusesShrunkOrTinyLists() {
    XCTAssertThrowsError(try Merge.check(list(count: 899), previous: list(count: 1000)))
    XCTAssertNoThrow(try Merge.check(list(count: 900), previous: list(count: 1000)))
    XCTAssertThrowsError(try Merge.check(list(count: 499), previous: nil))
}
```

- [ ] **Step 2: Run `swift test --filter MergeTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `Merge.swift`, `Fetch.swift` and `main.swift`.**
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: A live run with a small budget** (network, read-only on the sources):

Run: `cd app && STEPOVER_GAMES_STEAM_BUDGET=20 swift run -c release games-list build --fixes ../fixes --out /tmp/games.json && python3 -I -c "import json;d=json.load(open('/tmp/games.json'));print(len(d['games']), sum(1 for g in d['games'] if g.get('store')))"`
Expected: more than 1500 games, 10 with store facts, and RDR2's entry has `mac.crossover.rating` "perfect", `exes` ["RDR2.exe"] and `fix` true. Then `swift run -c release games-list verify /tmp/games.json` prints `ok: <count> games` (it decodes with the app's own `GamesList.decode`, exit 1 and `not a games list` otherwise).

- [ ] **Step 6: Commit** `"Games list builder: merge, Steam refresh and the games-list command"`

### Task 7: The daily workflow and the rolling release

**Files:**
- Create: `.github/workflows/games-list.yml`, `runtime/tests/test-games-workflow.sh`

**Interfaces:**
- Consumes: the `games-list` command (Task 6).
- Produces: the asset `https://github.com/<repo>/releases/download/games-list/games.json` (Task 1's `defaultSource`).

The workflow: `on: schedule: - cron: "41 10 * * *"` and `workflow_dispatch` with a boolean input `publish` (default true); `permissions: contents: write`; one job on `macos-15`, `timeout-minutes: 120`, `concurrency: games-list`. Steps:
1. `Checkout` (pinned SHA).
2. `Previous list`: `gh release download games-list -p games.json -O previous.json || true` (`GH_TOKEN: ${{ github.token }}`).
3. `Build`: `cd app && swift run -c release games-list build --fixes ../fixes --out ../games.json $( [ -f ../previous.json ] && echo --previous ../previous.json ) && swift run -c release games-list verify ../games.json`.
4. `Publish` (only when `github.event_name == 'schedule' || inputs.publish`): create the release when missing with `gh release create games-list --title "Games list" --prerelease --latest=false --notes "Updated daily by the Games list workflow. Mac test results from AppleGamingWiki (CC BY-NC-SA 3.0), anti-cheat data from AreWeAntiCheatYet (MIT)."`, then `gh release upload games-list games.json --clobber`.
5. `Keep a copy`: `actions/upload-artifact` (the pinned SHA from runtime.yml), 30 days.

`--latest=false` keeps the app releases (v0.3.0 and later) as the repository's latest release.

- [ ] **Step 1: Write the failing shell test** `runtime/tests/test-games-workflow.sh` (sourced by `run-tests.sh`, using its `assert_eq`): the workflow file exists; it has the cron line; the release is created with `--prerelease --latest=false`; upload uses `--clobber`; the publish step's `if:` names both the schedule and `inputs.publish`; every `uses:` is pinned to a 40-character SHA.
- [ ] **Step 2: Run `bash runtime/tests/run-tests.sh`.** Expected: the new assertions fail (no workflow yet).
- [ ] **Step 3: Write `.github/workflows/games-list.yml`.**
- [ ] **Step 4: Run `bash runtime/tests/run-tests.sh`.** Expected: `all passed`.
- [ ] **Step 5: Commit** `"Games list: daily workflow publishing a rolling release asset"`
- [ ] **Step 6 (maintainer's OK, outward-facing):** push the branch and run the workflow once with `publish: false` from the branch (`gh workflow run games-list.yml --ref library -f publish=false`), check the artifact's `games.json` like Task 6 step 5. Publishing waits for the merge to `main`, where the schedule takes over.

### Task 8: The snapshot inside the app, and docs

**Files:**
- Modify: `app/build-app.sh` (after the `runtime.json` line), `release/make-release.sh` (before `== app`), `docs/how-it-works.md`

**Interfaces:**
- Consumes: `GamesList.bundled()` (Task 1) reads `Contents/Resources/games.json`.

- `build-app.sh`: new documented env `STEPOVER_GAMES_JSON` (games list to embed, release builds); when set, copy it to `$STAGE/Contents/Resources/games.json`.
- `make-release.sh`: `curl -fsSL -o "$OUT/games.json" "https://github.com/$REPO/releases/download/games-list/games.json"`, failing with "no games list published yet: run the Games list workflow" when that fails; pass `STEPOVER_GAMES_JSON="$OUT/games.json"` to `build-app.sh`; `games.json` is not uploaded as a release asset (`publish.sh` already lists assets by name).
- `docs/how-it-works.md`: a "Games list" section: what the list holds and from where, the daily rolling release, that the app downloads it at most once a day and keeps its last copy, that matching happens on the Mac, the credits, and why ProtonDB isn't used.

- [ ] **Step 1: Write the failing check**: `STEPOVER_APP=<scratch>/T.app STEPOVER_BIN=none STEPOVER_GAMES_JSON=/tmp/games.json zsh app/build-app.sh && test -f <scratch>/T.app/Contents/Resources/games.json`. Expected now: the file is missing.
- [ ] **Step 2: Change `build-app.sh` and `make-release.sh`.**
- [ ] **Step 3: Run the check again.** Expected: the file is there, and `swift run games-list verify <scratch>/T.app/Contents/Resources/games.json` prints the same count as for `/tmp/games.json`.
- [ ] **Step 4: Run the full suites**: `cd app && swift test` and `bash runtime/tests/run-tests.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `"Games list: bundled snapshot and docs"`
