# Couch Mode Implementation Plan (Library plan B3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Library full screen on a TV, driven by a controller, with a controller shortcut that brings up Resume / Quit Game over a running game, so the maintainer never touches the Mac between games.

**Architecture:** Decisions with rules go in StepoverKit with tests: focus movement on the row, the shortcut detector (chords and hold times), which library game is running and how to quit just it, the in-game panel's choices, and the display arithmetic for "make this the main display". The app adds a full-screen `CouchView`, a controller/keyboard input bridge, a non-activating floating `NSPanel` for the in-game panel, and the display prompt. Task 1 is a hands-on spike with the maintainer's 8BitDo and TV that confirms the platform assumptions before the in-game panel is built.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (NSPanel, NSWindow full screen), GameController, ServiceManagement (`SMAppService` for Open at Login), CoreGraphics display configuration, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-28-couch-mode-design.md` (C1 to C7, anti-goals, Order). Builds on the Library (`2026-10-28-library-design.md`, plan B1: `Library.games`, `Verdicts`, `LibraryView`'s hero and pills).

## Global Constraints

- macOS 14 or later, Apple frameworks only, no new dependencies.
- Copy fixed by the spec: "Getting ready to play: N%", "Games open on your other screen", "Make This the Main Display", "Resume", "Quit Game", "Quit <running game> and play <game>", "Leave Couch Mode", "Show Hidden Games", "Stop Everything". No em dashes, no Wine words in couch mode.
- Never a Mac alert, sheet or file picker while couch mode is up (anti-goal); failures show on the TV with B to dismiss.
- Background controller listening only while a game Stepover started is running, and only for the two shortcuts; every press still reaches the game.
- Colors always paired with words; the Library's tones (`TileTone.rgb`) and contrast rules carry over.
- Logic in StepoverKit with tests; app code verified by the scripted AX check (`app/Tests/ui/`) and the maintainer's look.

## Review Focus

1. A held direction on the row: moves at a steady repeat, stops at the ends (no wrap), never skips past the last game. Test in Task 2.
2. Select+Start held for 0.9 s then released, or Home tapped: nothing fires; held past the threshold: fires once, not again until released. Test in Task 2.
3. A Steam game quit from the panel: only processes running from its folder are ended; Steam and other games in the bottle keep running. Test in Task 3.
4. The game ends by itself while the panel is open: the panel closes and couch mode comes back with that game selected. Checked in Task 6's hands-on run.
5. Couch mode on a display that isn't the main one: the prompt shows, and Make This the Main Display moves the menu bar there; on the main display no prompt. Tests in Task 5 (arithmetic) and Task 6 (hands-on).

---

### Task 1: Spike with the maintainer's controller and TV

**Files:**
- Create: `app/Tests/ui/controller-probe.swift` (a stand-alone tool, built with `swiftc`, not part of the package)

The probe is a tiny AppKit app (accessory, no Dock icon) that sets `GCController.shouldMonitorBackgroundEvents = true`, logs every button change of the extended gamepad with a timestamp and whether the probe is the active app, and on Select+Start held 1 s shows a borderless, non-activating `NSPanel` (`.nonactivatingPanel`, `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`, level `.screenSaver`) reading "Probe: shortcut seen" for 3 s.

- [ ] **Step 1:** Write and build the probe: `swiftc -O app/Tests/ui/controller-probe.swift -o <scratch>/controller-probe`.
- [ ] **Step 2 (maintainer):** With the 8BitDo connected and a Stepover game full screen on the TV (Hi-Fi Rush), the maintainer presses, in order: A, Home (tap, then hold 1 s), Select, Start, then Select+Start held 1 s. The probe's log records what arrived.
- [ ] **Step 3:** Record in the ledger, as facts: which buttons arrive in the background (Home? Select = `buttonOptions`? Start = `buttonMenu`?), whether the panel appeared over the full-screen game, whether the game kept the controller (its own reaction to A), whether macOS asked for Input Monitoring, and on which display the game opened. Expected per the spec: Select and Start arrive, the panel shows. If the panel does not show over the full-screen game, rule on the fallback before Task 4: a notification banner plus Stepover activating itself through `NSRunningApplication.current.activate(from:)` after `NSApp.yieldActivation`, and ledger it.
- [ ] **Step 4: Commit** the probe: `"Couch mode: controller probe for the hands-on spike"`

### Task 2: Moving and the shortcut, as rules

**Files:**
- Create: `app/Sources/StepoverKit/Couch.swift`
- Test: `app/Tests/StepoverKitTests/CouchTests.swift`

**Interfaces:**
- Produces:

```swift
public enum CouchButton: Hashable, Sendable { case up, down, left, right, a, b, x, y, menu, select, home }
public struct CouchRow: Sendable {               // focus on the row of games
    public private(set) var index: Int
    public let count: Int
    public init(count: Int, index: Int = 0)
    public mutating func move(_ step: Int)         // clamps to 0..<count, no wrap
    /// Held direction: first move at once, then one every `repeatEvery` seconds after `repeatAfter`.
    public static func repeats(heldFor seconds: Double, repeatAfter: Double = 0.4, repeatEvery: Double = 0.12) -> Int
}
public struct ShortcutDetector: Sendable {
    public static let homeHold = 0.5, chordHold = 1.0
    public init()
    /// Feed every button change with its time; true exactly once when Home has been held homeHold seconds or
    /// Select and Start together chordHold seconds. Re-arms only after the buttons are released.
    public mutating func update(_ pressed: Set<CouchButton>, at time: Double) -> Bool
}
public enum CouchAction: Equatable, Sendable { case play, resume, quitAndPlay(running: String), why, hide, back, menu, none }
public enum Couch {
    /// What A does on `selected` while `running` (a LibraryGame id) is running: play, resume, or quit-and-play.
    public static func primary(selected: String, running: String?) -> CouchAction
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testRowClampsAndRepeats() {
    var row = CouchRow(count: 4)
    row.move(-1); XCTAssertEqual(row.index, 0)
    row.move(10); XCTAssertEqual(row.index, 3)
    XCTAssertEqual(CouchRow.repeats(heldFor: 0.1), 1)
    XCTAssertEqual(CouchRow.repeats(heldFor: 0.4), 1)
    XCTAssertEqual(CouchRow.repeats(heldFor: 0.64), 3)     // 1 + two repeats at 0.52 and 0.64
}
func testShortcutFiresOncePerHold() {
    var d = ShortcutDetector()
    XCTAssertFalse(d.update([.select, .menu], at: 0))      // menu = Start
    XCTAssertFalse(d.update([.select, .menu], at: 0.9))
    XCTAssertTrue(d.update([.select, .menu], at: 1.0))
    XCTAssertFalse(d.update([.select, .menu], at: 1.5))    // still held: no second time
    XCTAssertFalse(d.update([], at: 1.6))
    XCTAssertFalse(d.update([.home], at: 2.0))
    XCTAssertTrue(d.update([.home], at: 2.5))
    XCTAssertFalse(d.update([.home], at: 2.2 + 0.1))       // time going backwards never fires
}
func testShortReleaseNeverFires() {
    var d = ShortcutDetector()
    _ = d.update([.select, .menu], at: 0); XCTAssertFalse(d.update([], at: 0.9)); XCTAssertFalse(d.update([.select, .menu], at: 1.2))
}
func testPrimaryAction() {
    XCTAssertEqual(Couch.primary(selected: "a", running: nil), .play)
    XCTAssertEqual(Couch.primary(selected: "a", running: "a"), .resume)
    XCTAssertEqual(Couch.primary(selected: "a", running: "b"), .quitAndPlay(running: "b"))
}
```

- [ ] **Step 2: Run `cd app && swift test --filter CouchTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `Couch.swift`.**
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit** `"Couch mode: row focus, shortcut detector, what A does"`

### Task 3: Which game is running, and quitting just it

**Files:**
- Modify: `app/Sources/StepoverKit/Couch.swift`
- Test: `app/Tests/StepoverKitTests/CouchTests.swift`

**Interfaces:**
- Consumes: `LibraryGame` (B1), `RunningPrograms.Process` (existing).
- Produces:

```swift
public enum QuitPlan: Equatable, Sendable { case processes([Int32]), bottle(Bottle) }
extension Couch {
    /// The library game that's running: a Steam game when a non-system process runs from its folder; a program
    /// when its exe is running in its bottle. Nil when none.
    public static func running(_ games: [LibraryGame], processes: [RunningPrograms.Process]) -> LibraryGame?
    /// How to quit just this game: a Steam game's own processes (Steam keeps running and syncs its saves), else its bottle.
    public static func quitPlan(_ game: LibraryGame, processes: [RunningPrograms.Process]) -> QuitPlan
}
```

The app carries out `.processes` with SIGTERM, then SIGKILL after 5 s for any still alive; `.bottle` with `Launcher.stop`.

- [ ] **Step 1: Write the failing tests** with fake processes: Steam (`C:\Program Files (x86)\Steam\steam.exe`), RDR2 (`...\steamapps\common\Red Dead Redemption 2\RDR2.exe`, cwd in the Steam bottle), Wine's own `C:\windows\explorer.exe`; a FitGirl bottle running `C:\Games\Sainthood\Sainthood.exe`.

```swift
func testRunningGameAndQuitPlan() {
    XCTAssertEqual(Couch.running(games, processes: steamProcs)?.name, "Red Dead Redemption 2")
    XCTAssertEqual(Couch.quitPlan(rdr2Tile, processes: steamProcs), .processes([202]))   // not Steam (201), not explorer
    XCTAssertEqual(Couch.running(games, processes: sainthoodProcs)?.name, "Sainthood")
    XCTAssertEqual(Couch.quitPlan(sainthoodTile, processes: sainthoodProcs), .bottle(sainthoodBottle))
    XCTAssertNil(Couch.running(games, processes: [steamOnly]))       // Steam alone isn't a game running
}
```

- [ ] **Step 2: Run `swift test --filter CouchTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `"Couch mode: the running game and how to quit just it"`

### Task 4: The couch screen

**Files:**
- Create: `app/Sources/StepoverApp/CouchView.swift`, `app/Sources/StepoverApp/ControllerInput.swift`
- Modify: `app/Sources/StepoverApp/Store.swift`, `app/Sources/StepoverApp/StepoverApp.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3; B1's `HeroView` pieces (`VerdictPill`, `CoverView`), `Store.library`, `playGame`, `setHidden`.
- Produces: `Store.couchMode: Bool` (View > Couch Mode ⌘⇧F; on at launch when a controller is connected unless the "openInCouchMode" default is false), `Store.openAtLogin` (SMAppService.mainApp), `ControllerInput` (publishes `CouchButton` presses from `GCController` value handlers, with held-direction repeats from `CouchRow.repeats`, and maps the keyboard to the same buttons: arrows = directions, Return = A, Escape = B, Space = X, Delete = Y, Tab = Menu).

Layout (C2, C3): native full screen of the window on its current screen; the selected game's cover blurred full-bleed behind the title (SF Pro Expanded, about 2.5x the window's), the two pills, Play, and (X) the reasons; one row of covers along the bottom, the selected one larger, scrolled to keep it in view; a footer of button hints with the buttons' words ("A Play  X Why  Y Hide  Menu"). A: `Couch.primary` (Play, Resume, or a confirm line "Quit <running> and play <game>" with A to confirm). Y: Hide, asking once more with A. Menu: a small list (Leave Couch Mode, Show Hidden Games, Stop Everything, Open at Login). C7: the runtime line and launch failures show on the screen (B dismisses); couch mode sets `Store.alert` aside (never presents a Mac alert while it's up). C6: when `Couch.running` goes from a game to nil, couch mode comes to the front (`NSApp.activate`) with that game selected.

- [ ] **Step 1: Write the scripted check first** (`app/Tests/ui/couch-check.sh`, the same harness as `library-check.sh`): open the test copy on a scratch home, press View > Couch Mode through the AX reader, then check through `axdump`: the button hints ("A Play", "X Why") are on screen; the first game's name and its verdict text are present; after `osascript -e 'tell application "System Events" to key code 124'` (Right) the selected game is the second one; after key code 48 (Tab = Menu) "Leave Couch Mode" is on screen; after key code 36 (Return) on it, the Library's "Your games" row is back. Run it. Expected: FAIL.
- [ ] **Step 2: Implement** `ControllerInput`, `CouchView`, the Store members and the View menu item.
- [ ] **Step 3: Run the scripted check, then both suites.** Expected: all pass.
- [ ] **Step 4: Commit** `"Couch mode: the full-screen controller Library"`

### Task 5: The in-game panel and the screen games open on

**Files:**
- Create: `app/Sources/StepoverApp/InGamePanel.swift`, `app/Sources/StepoverKit/DisplayLayout.swift`
- Modify: `app/Sources/StepoverApp/Store.swift`, `app/Sources/StepoverApp/CouchView.swift`
- Test: `app/Tests/StepoverKitTests/CouchTests.swift`

**Interfaces:**
- Consumes: Tasks 1 (the spike's facts and any ruling), 2 (`ShortcutDetector`), 3 (`Couch.running`, `quitPlan`).
- Produces:

```swift
public enum DisplayLayout {
    /// New origins (CG global coordinates) that make `target` the main display: every display shifted by the
    /// same amount so `target`'s origin becomes (0, 0).
    public static func originsMakingMain(_ target: CGRect, all: [CGRect]) -> [CGPoint]
}
```

In-game panel (C5): while `Couch.running` is non-nil (checked on Store's 2 s timer), `GCController.shouldMonitorBackgroundEvents = true` and every controller change goes through `ShortcutDetector`; when it fires, a borderless non-activating `NSPanel` (as the spike showed) appears centered on the game's screen with the game's name, Resume (A or B: close) and Quit Game (X, then A to confirm: carry out `quitPlan`). Background monitoring is off whenever no Stepover game runs. If the window was closed, firing the shortcut reopens it. Display (C2b): when couch mode's screen isn't `CGMainDisplayID()`, a line on the couch screen reads "Games open on your other screen" with Make This the Main Display (A when focused), which applies `originsMakingMain` with `CGBeginDisplayConfiguration` / `CGConfigureDisplayOrigin` / `CGCompleteDisplayConfiguration(.permanently)`.

- [ ] **Step 1: Write the failing test**

```swift
func testOriginsMakingMain() {
    let mac = CGRect(x: 0, y: 0, width: 1728, height: 1117), tv = CGRect(x: 1728, y: -200, width: 3840, height: 2160)
    XCTAssertEqual(DisplayLayout.originsMakingMain(tv, all: [mac, tv]), [CGPoint(x: -1728, y: 200), CGPoint(x: 0, y: 0)])
}
```

- [ ] **Step 2: Run `swift test --filter CouchTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `DisplayLayout`, `InGamePanel` and the wiring.**
- [ ] **Step 4: Run the tests and build the app.** Expected: pass, builds.
- [ ] **Step 5: Commit** `"Couch mode: in-game panel and the screen games open on"`

### Task 6: On the TV with the maintainer, and docs

**Files:**
- Modify: `docs/how-it-works.md` (a "Couch mode" section), `README.md` (one paragraph under Use)

- [ ] **Step 1 (maintainer, on the TV, using real Stepover games through a test copy on APFS clones):** enter couch mode with the controller connected at launch; move, Why, Hide (and back via Menu > Show Hidden Games); Play a game; during it hold Select+Start: the panel; Resume; again, Quit Game: back on the row with that game selected; Play another game while one runs: "Quit X and play Y"; let a game end by itself: back on the row; if the TV isn't the main display, the prompt and Make This the Main Display. Fix what the maintainer finds (each with a failing Kit test or a scripted-check line).
- [ ] **Step 2:** Docs: what couch mode is, the shortcut, Open at Login, the Home button note (System Settings > Game Controllers), the main-display prompt.
- [ ] **Step 3:** Remove the scratch copies; run both suites. Expected: all pass.
- [ ] **Step 4: Commit** `"Couch mode: docs"`
