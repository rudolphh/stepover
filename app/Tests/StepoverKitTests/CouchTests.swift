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
}
