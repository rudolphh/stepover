import XCTest
@testable import StepoverKit

/// Installed games the games list doesn't know, looked up once on Steam's store from this Mac (Sainthood,
/// I Am Jesus Christ): cover and Steam facts, exact single matches only, misses retried after 30 days.
final class LearnedGamesTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let search = Data(#"{"total":4,"items":[{"id":4545760,"name":"Sainthood Relics"},{"id":3974320,"name":"Sainthood: Confession"},{"id":1748600,"name":"Sainthood"},{"id":2537870,"name":"Sainthood Demo"}]}"#.utf8)
    private let details = Data(#"{"1748600":{"success":true,"data":{"type":"game","name":"Sainthood","platforms":{"windows":true,"mac":false},"categories":[{"id":2},{"id":28}]}}}"#.utf8)
    private let deck = Data(#"{"success":1,"results":{"resolved_category":0,"resolved_items":[]}}"#.utf8)

    private func steam(_ answers: [String: Data]) -> SteamLookup.Fetch {
        { url in
            guard let key = answers.keys.first(where: { url.absoluteString.contains($0) }) else { throw URLError(.notConnectedToInternet) }
            return answers[key]!
        }
    }

    func testExactMatch() {
        XCTAssertEqual(SteamStore.exactMatch(SteamStore.searchResults(search)!, for: "Sainthood"), 1748600)
        XCTAssertNil(SteamStore.exactMatch([(id: 1, name: "Mafia: Definitive Edition")], for: "Mafia"))
        XCTAssertNil(SteamStore.exactMatch([(id: 1, name: "Doom"), (id: 2, name: "DOOM")], for: "Doom"))
    }

    func testLearnByName() async throws {
        let answers = ["storesearch": search, "appdetails": details, "deckappcompat": deck]
        let entry = try await SteamLookup.learn(name: "Sainthood", appID: nil, today: "2026-10-28", fetch: steam(answers))
        XCTAssertEqual(entry?.id, "steam:1748600")
        XCTAssertEqual(entry?.steam, 1748600)
        XCTAssertEqual(entry?.store?.controller, .full)
        XCTAssertEqual(entry?.deck?.category, .unknown)
        let none = try await SteamLookup.learn(name: "Not A Steam Game", appID: nil, today: "2026-10-28",
                                              fetch: steam(["storesearch": Data(#"{"total":0,"items":[]}"#.utf8)]))
        XCTAssertNil(none)
    }

    func testLearnByAppID() async throws {
        let entry = try await SteamLookup.learn(name: "whatever", appID: 1748600, today: "2026-10-28",
                                                fetch: steam(["appdetails": details, "deckappcompat": deck]))
        XCTAssertEqual(entry?.name, "Sainthood")
    }

    func testOfflineThrowsSoNothingIsRemembered() async {
        do {
            _ = try await SteamLookup.learn(name: "Sainthood", appID: nil, today: "2026-10-28", fetch: steam([:]))
            XCTFail("offline must throw")
        } catch {}
    }

    func testLibraryUsesLearnedGamesAndListsWhatToLookUp() {
        let url = dir.appendingPathComponent("Sainthood")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let bottle = Bottle(url: url)
        let programs = [Program(name: "Sainthood", exe: #"C:\Games\Sainthood\Sainthood.exe"#),
                        Program(name: "Homebrew Thing", exe: #"C:\Games\X\X.exe"#)]
        let list = GameIndex(GamesList(format: 1, generated: "", credits: [], games: []))
        var learned = LearnedGames()
        let before = Library.games(bottles: [(bottle, BottleConfig(programs: programs))], steamApps: { _ in [] }, index: list, recent: [])
        XCTAssertEqual(Library.lookups(before, learned: learned, today: "2026-10-28").map(\.name), ["Homebrew Thing", "Sainthood"])

        learned.entries = [GameEntry(id: "steam:1748600", name: "Sainthood", steam: 1748600)]
        learned.misses = [GameName.normalized("Homebrew Thing"): "2026-10-20"]
        let after = Library.games(bottles: [(bottle, BottleConfig(programs: programs))], steamApps: { _ in [] }, index: list,
                                  recent: [], learned: GameIndex(GamesList(format: 1, generated: "", credits: [], games: learned.entries)))
        XCTAssertEqual(after.first { $0.name == "Sainthood" }?.steamAppID, 1748600)
        XCTAssertEqual(Library.lookups(after, learned: learned, today: "2026-10-28").map(\.name), [])   // miss is recent
        XCTAssertEqual(Library.lookups(after, learned: learned, today: "2026-12-01").map(\.name), ["Homebrew Thing"])
    }

    func testLearnedGamesSurviveASave() throws {
        let file = dir.appendingPathComponent("learned-games.json")
        XCTAssertTrue(LearnedGames.load(from: file).entries.isEmpty)
        try LearnedGames(entries: [GameEntry(id: "steam:1", name: "A", steam: 1)], misses: ["b": "2026-10-28"]).save(to: file)
        XCTAssertEqual(LearnedGames.load(from: file).entries.first?.steam, 1)
        XCTAssertEqual(LearnedGames.load(from: file).misses, ["b": "2026-10-28"])
    }
}
