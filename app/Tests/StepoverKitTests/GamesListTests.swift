import XCTest
@testable import StepoverKit

final class GamesListTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("games-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let rdr2: [String: Any] = [
        "id": "steam:1174180", "name": "Red Dead Redemption 2", "names": [String](), "steam": 1174180,
        "exes": ["RDR2.exe"], "agwPage": "Red Dead Redemption 2", "fix": true,
        "mac": ["crossover": ["rating": "perfect", "device": "MacBook Air M3", "method": "Crossover 25.0", "date": "2025-05-05"],
                "wine": ["rating": "unplayable"]],
        "store": ["macVersion": false, "singlePlayer": true, "controller": "partial", "checked": "2026-10-28"],
        "deck": ["category": 2, "controllerWorks": true, "checked": "2026-10-28"],
    ]

    private func json(format: Int, games: [[String: Any]]? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["format": format, "generated": "2026-10-28T10:41:00Z",
                                                     "credits": ["AppleGamingWiki"], "games": games ?? [rdr2]])
    }

    func testDecodesFormat1() {
        let list = GamesList.decode(json(format: 1))
        XCTAssertEqual(list?.games.first?.steam, 1174180)
        XCTAssertEqual(list?.games.first?.mac?.crossover?.rating, .perfect)
        XCTAssertEqual(list?.games.first?.deck?.category, .playable)
        XCTAssertEqual(list?.games.first?.store?.controller, .partial)
    }

    func testRejectsNewerFormatGarbageAndEmpty() {
        XCTAssertNil(GamesList.decode(json(format: 2)))
        XCTAssertNil(GamesList.decode(Data("<html>rate limited</html>".utf8)))
        XCTAssertNil(GamesList.decode(json(format: 1, games: [])))
    }

    func testRatingsOrderWorstToBest() {
        XCTAssertLessThan(MacRating.unplayable, .runs)
        XCTAssertLessThan(MacRating.playable, .perfect)
        XCTAssertEqual([MacRating.playable, .perfect, .runs].max(), .perfect)
    }

    func testLoadFallsBackToBundledThenEmpty() throws {
        let cache = dir.appendingPathComponent("games-list.json")
        let bundled = GamesList.decode(json(format: 1))!
        XCTAssertEqual(GamesList.load(cache: cache, bundled: bundled).games.count, 1)
        try Data("broken".utf8).write(to: cache)
        XCTAssertEqual(GamesList.load(cache: cache, bundled: bundled).games.count, 1)
        XCTAssertTrue(GamesList.load(cache: cache, bundled: nil).games.isEmpty)
    }

    func testFetchKeepsCacheOnBadData() async throws {
        let cache = dir.appendingPathComponent("games-list.json"), bad = dir.appendingPathComponent("bad.json")
        try json(format: 1).write(to: cache)
        try json(format: 1, games: []).write(to: bad)
        let updated = await GamesList.fetch(from: bad.path, to: cache)
        XCTAssertFalse(updated)
        XCTAssertEqual(GamesList.load(cache: cache, bundled: nil).games.count, 1)
        let unreachable = await GamesList.fetch(from: "https://127.0.0.1:9/games.json", to: cache)
        XCTAssertFalse(unreachable)
        XCTAssertEqual(GamesList.load(cache: cache, bundled: nil).games.count, 1)
    }

    func testFetchWritesGoodData() async throws {
        let cache = dir.appendingPathComponent("games-list.json"), good = dir.appendingPathComponent("good.json")
        var second = rdr2
        second["id"] = "steam:1817230"; second["steam"] = 1817230; second["name"] = "Hi-Fi RUSH"
        try json(format: 1, games: [rdr2, second]).write(to: good)
        let updated = await GamesList.fetch(from: good.path, to: cache)
        XCTAssertTrue(updated)
        XCTAssertEqual(GamesList.load(cache: cache, bundled: nil).games.map(\.name), ["Red Dead Redemption 2", "Hi-Fi RUSH"])
    }

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

    func testBundledReadsResources() throws {
        let app = dir.appendingPathComponent("Foo.app"), resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.foo</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"#.utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(GamesList.bundled(bundle: Bundle(url: app)))
        try json(format: 1).write(to: resources.appendingPathComponent("games.json"))
        XCTAssertEqual(GamesList.bundled(bundle: Bundle(url: app))?.games.count, 1)
    }
}
