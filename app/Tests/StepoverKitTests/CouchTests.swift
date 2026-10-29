import XCTest
@testable import StepoverKit

final class CouchTests: XCTestCase {
    func testRowClampsAndRepeats() {
        var row = CouchRow(count: 4)
        row.move(-1); XCTAssertEqual(row.index, 0)
        row.move(10); XCTAssertEqual(row.index, 3)
        row.move(-1); XCTAssertEqual(row.index, 2)
        XCTAssertEqual(CouchRow(count: 0).index, 0)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.1), 1)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.4), 1)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.64), 3)     // 1 + repeats at 0.52 and 0.64
    }

    func testShortcutFiresOncePerHold() {
        var d = ShortcutDetector()
        XCTAssertFalse(d.update([.select, .menu], at: 0))      // menu is Start
        XCTAssertFalse(d.update([.select, .menu], at: 0.9))
        XCTAssertTrue(d.update([.select, .menu], at: 1.0))
        XCTAssertFalse(d.update([.select, .menu], at: 1.5))    // still held: no second time
        XCTAssertFalse(d.update([], at: 1.6))
        XCTAssertFalse(d.update([.home], at: 2.0))
        XCTAssertTrue(d.update([.home], at: 2.5))
        XCTAssertFalse(d.update([.home], at: 2.3))             // time going backwards never fires again
    }

    func testShortReleaseNeverFires() {
        var d = ShortcutDetector()
        XCTAssertFalse(d.update([.select, .menu], at: 0))
        XCTAssertFalse(d.update([], at: 0.9))
        XCTAssertFalse(d.update([.select, .menu], at: 1.2))    // a fresh hold starts at 1.2
        XCTAssertFalse(d.update([.select, .menu, .a], at: 2.1))
        XCTAssertTrue(d.update([.select, .menu], at: 2.2))
        XCTAssertFalse(d.update([.select], at: 5))             // one button alone is never the chord
    }

    func testPrimaryAction() {
        XCTAssertEqual(Couch.primary(selected: "a", running: nil), .play)
        XCTAssertEqual(Couch.primary(selected: "a", running: "a"), .resume)
        XCTAssertEqual(Couch.primary(selected: "a", running: "b"), .quitAndPlay(running: "b"))
    }

    // the hands-on test: Play moved Red Dead to the front of the row and the highlight stayed behind
    func testFocusFollowsTheGame() {
        XCTAssertEqual(CouchRow(ids: ["rdr2", "hifi", "iajc"], focus: "rdr2", fallback: 2).index, 0)
        // hidden, so gone from the row: the game that took its place
        XCTAssertEqual(CouchRow(ids: ["hifi", "iajc"], focus: "sainthood", fallback: 1).index, 1)
        XCTAssertEqual(CouchRow(ids: ["hifi"], focus: "sainthood", fallback: 3).index, 0)
        XCTAssertEqual(CouchRow(ids: ["hifi", "iajc"], focus: nil, fallback: 0).index, 0)
    }

    // the hands-on test: a game hidden from the couch had no way back with the controller
    func testYHidesOrBringsBack() {
        XCTAssertEqual(Couch.secondary(hidden: false), .hide)
        XCTAssertEqual(Couch.secondary(hidden: true), .unhide)
    }

    // the hands-on test: the A that confirmed Quit also pressed A in the game. The game is paused while the panel
    // is up, and Resume continues it only once every button is let go (a held A would reach it on continuing)
    func testResumeWaitsForRelease() {
        var pause = InGamePause()
        XCTAssertEqual(pause.update([]), [])                     // nothing paused
        XCTAssertEqual(pause.pause("a", pids: [1, 2]), [1, 2])
        pause.resume()
        XCTAssertEqual(pause.update([.a]), [])                   // the A that chose Resume is still down
        XCTAssertEqual(pause.update([.a, .b]), [])
        XCTAssertEqual(pause.update([]), [1, 2])                 // all let go: continue now
        XCTAssertEqual(pause.update([]), [])                     // once
    }

    // final review I1, I2: a paused game is never left paused
    func testAPausedGameIsAlwaysContinued() {
        var pause = InGamePause()
        _ = pause.pause("a", pids: [1])
        XCTAssertEqual(pause.watching("a"), [])                  // still the same game
        XCTAssertEqual(pause.watching("b"), [1])                 // another game took over: continue it now
        _ = pause.pause("a", pids: [3])
        XCTAssertEqual(pause.watching(nil), [3])                 // the game is gone
        _ = pause.pause("a", pids: [4])
        XCTAssertEqual(pause.quit(), [4])                        // a stopped process can't take a quit signal
        XCTAssertEqual(pause.update([]), [])
        // a second shortcut right after Resume, a button still down: the pending Resume doesn't continue it under the panel
        _ = pause.pause("a", pids: [5])
        pause.resume()
        XCTAssertEqual(pause.pause("a", pids: [5]), [5])
        XCTAssertEqual(pause.update([]), [])
        XCTAssertEqual(pause.paused, [5])
    }

    // final review I1: quitting a Steam game continues its processes first, asks them to end, and finishes as soon as
    // they're gone, killing what's left after the grace period
    func testEndingProcesses() async {
        final class Log: @unchecked Sendable { var signals: [String] = []; var alive: Set<Int32> = [7, 8]; var ticks = 0 }
        let log = Log()
        await ProcessEnd.end([7, 8], grace: 1, step: 0.25,
                             signal: { pid, sig in log.signals.append("\(pid):\(sig)"); if sig == SIGKILL { log.alive.remove(pid) } },
                             alive: { log.alive.contains($0) },
                             sleep: { _ in log.ticks += 1; if log.ticks == 2 { log.alive.remove(7) } })
        XCTAssertEqual(Array(log.signals.prefix(4)), ["7:\(SIGCONT)", "7:\(SIGTERM)", "8:\(SIGCONT)", "8:\(SIGTERM)"])
        XCTAssertEqual(log.signals.last, "8:\(SIGKILL)")         // 8 ignored SIGTERM through the grace period
        XCTAssertFalse(log.signals.contains("7:\(SIGKILL)"))     // 7 ended by itself
        log.alive = [9]; log.signals = []; log.ticks = 0
        await ProcessEnd.end([9], grace: 5, step: 0.25, signal: { pid, sig in log.signals.append("\(pid):\(sig)") },
                             alive: { log.alive.contains($0) }, sleep: { _ in log.ticks += 1; log.alive.removeAll() })
        XCTAssertEqual(log.ticks, 1)                              // gone at the first look: no waiting out the grace period
    }

    // the hands-on test: with several desktops (or couch mode's full screen) a started game opened out of sight
    func testGameWindowWorthShowing() {
        let strip = GameWindow(pid: 7, layer: 0, width: 1728, height: 33)     // Wine's menu bar strip
        let helper = GameWindow(pid: 7, layer: 0, width: 500, height: 500)    // the hidden window Wine opens first
        let other = GameWindow(pid: 9, layer: 0, width: 1728, height: 1080)
        XCTAssertFalse(Couch.hasGameWindow(pids: [7], windows: [strip, helper, other]))
        XCTAssertTrue(Couch.hasGameWindow(pids: [7], windows: [strip, GameWindow(pid: 7, layer: 0, width: 1728, height: 1080)]))
        XCTAssertTrue(Couch.hasGameWindow(pids: [7], windows: [GameWindow(pid: 7, layer: 0, width: 800, height: 600)]))
        XCTAssertFalse(Couch.hasGameWindow(pids: [7], windows: [GameWindow(pid: 7, layer: 25, width: 1728, height: 1080)]))
    }

    // a game takes seconds to show up; a second A meanwhile would start another copy
    func testAWaitsWhileAGameStarts() {
        XCTAssertEqual(Couch.primary(selected: "rdr2", running: nil, starting: "rdr2"), .none)
        XCTAssertEqual(Couch.primary(selected: "hifi", running: nil, starting: "rdr2"), .none)
        XCTAssertEqual(Couch.primary(selected: "rdr2", running: "rdr2", starting: "rdr2"), .resume)
    }

    // Task 3: which game is running, and quitting just it
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("couch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func bottle(_ name: String) -> Bottle {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        return Bottle(url: url)
    }

    private func cwd(_ bottle: Bottle) -> String { bottle.url.resolvingSymlinksInPath().path + "/drive_c" }

    // the hands-on test: RDR2.exe hands off to Launcher.exe and a second RDR2.exe named without a path, so Red Dead
    // looked ended, couch mode came back over it, and the next A started a second copy
    func testGameRunningAfterItsExeHandsOff() {
        let rdr2 = bottle("RDR2")
        let program = Program(name: "Red Dead Redemption 2", exe: #"C:\Program Files\Red Dead Redemption 2\RDR2.exe"#)
        let tile = LibraryGame(id: "r|Red Dead Redemption 2", name: "Red Dead Redemption 2", bottle: rdr2, kind: .program(program),
                               entry: nil, lastPlayed: nil, steamAppID: nil, launch: program)
        let launcher = RunningPrograms.Process(pid: 1, windowsPath: #"C:\Program Files\Red Dead Redemption 2\Launcher.exe"#, cwd: cwd(rdr2))
        let bare = RunningPrograms.Process(pid: 2, windowsPath: "RDR2.exe", cwd: cwd(rdr2))
        XCTAssertEqual(Couch.running([tile], processes: [launcher])?.id, tile.id)
        XCTAssertEqual(Couch.running([tile], processes: [bare])?.id, tile.id)
        XCTAssertTrue(RunningPrograms.isProgramName("RDR2.exe"))
        XCTAssertTrue(RunningPrograms.isProgramName(#"C:\Games\Sainthood\Sainthood.exe"#))
        XCTAssertFalse(RunningPrograms.isProgramName("/usr/bin/zsh"))
        XCTAssertFalse(RunningPrograms.isProgramName("zsh"))
        // a game at a drive's root doesn't claim everything on that drive
        let root = Program(name: "Root", exe: #"C:\game.exe"#)
        let rootTile = LibraryGame(id: "r|Root", name: "Root", bottle: rdr2, kind: .program(root),
                                   entry: nil, lastPlayed: nil, steamAppID: nil, launch: root)
        XCTAssertNil(Couch.running([rootTile], processes: [launcher]))
    }

    // final review I2: a game a previous Stepover left paused (it crashed or was force quit with the panel up) is found
    func testStrayPausedGame() {
        let rdr2 = bottle("RDR2")
        let program = Program(name: "Red Dead Redemption 2", exe: #"C:\Program Files\Red Dead Redemption 2\RDR2.exe"#)
        let tile = LibraryGame(id: "r|Red Dead Redemption 2", name: "Red Dead Redemption 2", bottle: rdr2, kind: .program(program),
                               entry: nil, lastPlayed: nil, steamAppID: nil, launch: program)
        let game = RunningPrograms.Process(pid: 1, windowsPath: "RDR2.exe", cwd: cwd(rdr2))
        let wine = RunningPrograms.Process(pid: 2, windowsPath: #"C:\windows\system32\services.exe"#, cwd: cwd(rdr2))
        let stopped: Set<Int32> = [1, 2]
        XCTAssertEqual(Couch.strayPaused([tile], processes: [game, wine], isStopped: { stopped.contains($0) }, ours: []), [1])
        XCTAssertEqual(Couch.strayPaused([tile], processes: [game, wine], isStopped: { stopped.contains($0) }, ours: [1]), [])
        XCTAssertEqual(Couch.strayPaused([tile], processes: [game], isStopped: { _ in false }, ours: []), [])
    }

    func testStoppedProcess() throws {
        let sleeper = Foundation.Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run()
        defer { kill(sleeper.processIdentifier, SIGCONT); sleeper.terminate() }
        let pid = sleeper.processIdentifier
        XCTAssertFalse(RunningPrograms.isStopped(pid))
        kill(pid, SIGSTOP); usleep(200_000)
        XCTAssertTrue(RunningPrograms.isStopped(pid))
        kill(pid, SIGCONT); usleep(200_000)
        XCTAssertFalse(RunningPrograms.isStopped(pid))
    }

    // final review I5: a Steam game whose exe hands off to a bare-named copy of itself is still running and quit whole
    func testSteamGameRunningAfterItsExeHandsOff() throws {
        let steam = bottle("Steam")
        let folder = #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2"#
        let mac = try XCTUnwrap(WindowsPath.toMac(folder, bottle: steam))
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mac.appendingPathComponent("RDR2.exe").path, contents: Data())
        let app = SteamApp(id: 1174180, name: "Red Dead Redemption 2", folder: mac, windowsFolder: folder)
        let client = Program(name: "Steam", exe: #"C:\Program Files (x86)\Steam\steam.exe"#)
        let tile = LibraryGame(id: "s|steam:1174180", name: "Red Dead Redemption 2", bottle: steam, kind: .steamGame(app),
                               entry: nil, lastPlayed: nil, steamAppID: 1174180, launch: client)
        let bare = RunningPrograms.Process(pid: 3, windowsPath: "RDR2.exe", cwd: cwd(steam))
        let other = RunningPrograms.Process(pid: 4, windowsPath: "Other.exe", cwd: cwd(steam))
        XCTAssertEqual(Couch.running([tile], processes: [bare])?.id, tile.id)
        XCTAssertEqual(Couch.quitPlan(tile, processes: [bare, other]), .processes([3]))
    }

    func testRunningGameAndQuitPlan() {
        let steam = bottle("Steam"), sainthood = bottle("Sainthood")
        let client = Program(name: "Steam", exe: #"C:\Program Files (x86)\Steam\steam.exe"#)
        let folder = #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2"#
        let app = SteamApp(id: 1174180, name: "Red Dead Redemption 2", folder: steam.url, windowsFolder: folder)
        let program = Program(name: "Sainthood", exe: #"C:\Games\Sainthood\Sainthood.exe"#)
        let rdr2Tile = LibraryGame(id: "s|steam:1174180", name: "Red Dead Redemption 2", bottle: steam, kind: .steamGame(app),
                                   entry: nil, lastPlayed: nil, steamAppID: 1174180, launch: client)
        let clientTile = LibraryGame(id: "s|steam", name: "Steam", bottle: steam, kind: .steamClient(client),
                                     entry: nil, lastPlayed: nil, steamAppID: nil, launch: client)
        let sainthoodTile = LibraryGame(id: "h|Sainthood", name: "Sainthood", bottle: sainthood, kind: .program(program),
                                        entry: nil, lastPlayed: nil, steamAppID: nil, launch: program)
        let games = [rdr2Tile, sainthoodTile, clientTile]
        let steamOnly = RunningPrograms.Process(pid: 201, windowsPath: client.exe, cwd: cwd(steam))
        let steamProcs = [steamOnly, RunningPrograms.Process(pid: 202, windowsPath: folder + #"\RDR2.exe"#, cwd: cwd(steam)),
                          RunningPrograms.Process(pid: 203, windowsPath: #"C:\windows\explorer.exe"#, cwd: cwd(steam))]
        let sainthoodProcs = [RunningPrograms.Process(pid: 301, windowsPath: program.exe, cwd: cwd(sainthood))]

        XCTAssertEqual(Couch.running(games, processes: steamProcs)?.name, "Red Dead Redemption 2")
        XCTAssertEqual(Couch.quitPlan(rdr2Tile, processes: steamProcs), .processes([202]))   // not Steam, not explorer
        XCTAssertEqual(Couch.processes(of: rdr2Tile, in: steamProcs).map(\.pid), [202])   // what Resume brings forward
        XCTAssertEqual(Couch.running(games, processes: sainthoodProcs)?.name, "Sainthood")
        XCTAssertEqual(Couch.quitPlan(sainthoodTile, processes: sainthoodProcs), .bottle(sainthood))
        XCTAssertNil(Couch.running(games, processes: [steamOnly]))     // Steam alone isn't a game running
        XCTAssertNil(Couch.running(games, processes: []))
    }

    // Task 5: making the TV the main display moves every screen by the same amount
    func testOriginsMakingMain() {
        let mac = CGRect(x: 0, y: 0, width: 1728, height: 1117), tv = CGRect(x: 1728, y: -200, width: 3840, height: 2160)
        XCTAssertEqual(DisplayLayout.originsMakingMain(tv, all: [mac, tv]), [CGPoint(x: -1728, y: 200), CGPoint(x: 0, y: 0)])
        XCTAssertEqual(DisplayLayout.originsMakingMain(mac, all: [mac, tv]), [CGPoint(x: 0, y: 0), CGPoint(x: 1728, y: -200)])
    }

    // Task 5: presses count only while Stepover is in front, and a button held across coming back doesn't
    func testPressesOnlyWhileInFront() {
        var t = PressTracker()
        XCTAssertEqual(t.update([.a], at: 0, active: true), [.a])
        XCTAssertEqual(t.update([.a], at: 0.5, active: true), [])            // held: once
        XCTAssertEqual(t.update([], at: 0.6, active: true), [])
        XCTAssertEqual(t.update([.a], at: 1, active: false), [])             // a game has the controller
        XCTAssertEqual(t.update([.a], at: 1.1, active: true), [])            // still held on coming back
        XCTAssertEqual(t.update([], at: 1.2, active: true), [])
        XCTAssertEqual(t.update([.a], at: 1.3, active: true), [.a])
        XCTAssertEqual(t.update([.right], at: 2, active: true), [.right])
        XCTAssertEqual(t.update([.right], at: 2.64, active: true), [.right, .right])   // CouchRow.repeats' pace
        XCTAssertEqual(t.update([.right], at: 3, active: false), [])
    }

    // Task 5: the in-game panel: A or B resumes, X asks, then A quits and B goes back
    func testInGameMenu() {
        var m = InGameMenu()
        XCTAssertEqual(m.press(.a), .resume)
        XCTAssertEqual(m.press(.b), .resume)
        XCTAssertEqual(m.press(.y), .none)
        XCTAssertEqual(m.press(.x), .none); XCTAssertTrue(m.confirming)
        XCTAssertEqual(m.press(.x), .none); XCTAssertTrue(m.confirming)
        XCTAssertEqual(m.press(.b), .none); XCTAssertFalse(m.confirming)
        XCTAssertEqual(m.press(.x), .none)
        XCTAssertEqual(m.press(.a), .quit)
    }
}
