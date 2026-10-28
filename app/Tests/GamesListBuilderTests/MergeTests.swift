import XCTest
@testable import GamesListBuilder

final class MergeTests: XCTestCase {
    private let rdr2Page = AGWPage(title: "Red Dead Redemption 2", steam: 1174180, tests: MacTests(crossover: MacTest(rating: .perfect)))
    private let hiFiPage = AGWPage(title: "HI-Fi RUSH", steam: 1817230, tests: MacTests(crossover: MacTest(rating: .perfect)))
    private let fortnite = AntiCheatGame(name: "Fortnite", slug: "fortnite", status: "Denied", anticheats: ["Easy Anti-Cheat"],
                                         steam: nil, epic: "fn/fortnite")
    private let apex = AntiCheatGame(name: "Apex Legends", slug: "apex-legends", status: "Denied",
                                     anticheats: ["Easy Anti-Cheat", "Hyperion"], steam: 1172470, epic: nil)
    private let rdr2Fix = Fix(name: "Red Dead Redemption 2", match: .init(steam: [1174180], exe: ["RDR2.exe"]))

    private func list(_ games: [GameEntry]) -> GamesList { GamesList(format: 1, generated: "", credits: [], games: games) }

    private func list(count: Int) -> GamesList {
        list((0..<count).map { GameEntry(id: "steam:\($0)", name: "Game \($0)", steam: $0) })
    }

    func testMergeJoinsSourcesBySteamID() {
        let games = Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [fortnite], fixes: [rdr2Fix], mostPlayed: [730]), previous: nil)
        let rdr2 = games.first { $0.steam == 1174180 }
        XCTAssertEqual(rdr2?.id, "steam:1174180")
        XCTAssertEqual(rdr2?.name, "Red Dead Redemption 2")
        XCTAssertEqual(rdr2?.names, [])                       // the fix's name is the same game name
        XCTAssertEqual(rdr2?.exes, ["RDR2.exe"])
        XCTAssertEqual(rdr2?.fix, true)
        XCTAssertEqual(rdr2?.agwPage, "Red Dead Redemption 2")
        XCTAssertEqual(rdr2?.mac?.crossover?.rating, .perfect)
        let fn = games.first { $0.epic == "fn/fortnite" }
        XCTAssertEqual(fn?.id, "acy:fortnite")
        XCTAssertEqual(fn?.antiCheat, AntiCheat(names: ["Easy Anti-Cheat"], status: "Denied"))
        XCTAssertNotNil(games.first { $0.id == "steam:730" })   // most played: Steam fills in its name
        XCTAssertEqual(games.map(\.id), games.map(\.id).sorted())
    }

    func testSteamNameWinsAndOtherNamesStay() {
        var previous = Merge.entries(BuildSources(agw: [hiFiPage], antiCheat: [], fixes: [], mostPlayed: nil), previous: nil)
        previous[0].name = "Hi-Fi RUSH"
        previous[0].store = StoreFacts(macVersion: false, singlePlayer: true, controller: .full, checked: "2026-10-27")
        let games = Merge.entries(BuildSources(agw: [AGWPage(title: "Hi-Fi Rush (2023)", steam: 1817230, tests: hiFiPage.tests)],
                                               antiCheat: [], fixes: [], mostPlayed: nil), previous: list(previous))
        XCTAssertEqual(games.first?.name, "Hi-Fi RUSH")
        XCTAssertEqual(games.first?.names, ["Hi-Fi Rush (2023)"])
        XCTAssertEqual(games.first?.store?.checked, "2026-10-27")
    }

    func testFailedSourceKeepsPreviousData() {
        let previous = list(Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [apex], fixes: [], mostPlayed: nil), previous: nil))
        let games = Merge.entries(BuildSources(agw: nil, antiCheat: nil, fixes: [], mostPlayed: nil), previous: previous)
        XCTAssertEqual(games.first { $0.steam == 1174180 }?.mac?.crossover?.rating, .perfect)
        XCTAssertEqual(games.first { $0.steam == 1172470 }?.antiCheat?.names, ["Easy Anti-Cheat", "Hyperion"])
    }

    func testSourceThatWorkedDropsWhatItNoLongerLists() {
        let previous = list(Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [apex], fixes: [], mostPlayed: nil), previous: nil))
        let games = Merge.entries(BuildSources(agw: [rdr2Page], antiCheat: [], fixes: [], mostPlayed: nil), previous: previous)
        XCTAssertNil(games.first { $0.steam == 1172470 })     // nothing else knew about it
        XCTAssertNotNil(games.first { $0.steam == 1174180 })
    }

    func testSteamToRefresh() {
        func facts(_ checked: String) -> StoreFacts { StoreFacts(macVersion: false, singlePlayer: true, controller: nil, checked: checked) }
        let entries = [GameEntry(id: "steam:1", name: "A", steam: 1, store: facts("2026-10-01")),
                       GameEntry(id: "steam:2", name: "B", steam: 2, store: facts("2026-10-27")),
                       GameEntry(id: "steam:3", name: "C", steam: 3),
                       GameEntry(id: "acy:x", name: "X")]
        XCTAssertEqual(Merge.steamToRefresh(entries, today: "2026-10-28", limit: 10), [3, 1])
        XCTAssertEqual(Merge.steamToRefresh(entries, today: "2026-10-28", limit: 1), [3])
    }

    func testPickSteamIDExactAndUnique() {
        let hollow = [(id: 367520, name: "Hollow Knight"), (id: 1030300, name: "Hollow Knight: Silksong"),
                      (id: 598190, name: "Hollow Knight - Official Soundtrack")]
        XCTAssertEqual(Merge.pickSteamID(hollow, for: "Hollow Knight"), 367520)
        XCTAssertNil(Merge.pickSteamID([(id: 55230, name: "Saints Row: The Third")], for: "Sainthood"))
        XCTAssertNil(Merge.pickSteamID([(id: 1, name: "Doom"), (id: 2, name: "DOOM")], for: "Doom"))
    }

    func testSteamToSearch() {
        let entries = [GameEntry(id: "agw:A", name: "A", agwPage: "A"),
                       GameEntry(id: "agw:B", name: "B", agwPage: "B", steamSearched: "2026-10-20"),
                       GameEntry(id: "agw:C", name: "C", agwPage: "C", steamSearched: "2026-08-01"),
                       GameEntry(id: "steam:4", name: "D", steam: 4, agwPage: "D"),
                       GameEntry(id: "acy:e", name: "E")]
        XCTAssertEqual(Merge.steamToSearch(entries, today: "2026-10-28", limit: 10), ["agw:A", "agw:C"])
        XCTAssertEqual(Merge.steamToSearch(entries, today: "2026-10-28", limit: 1), ["agw:A"])
    }

    func testResolveMovesTheWikiEntryIntoTheSteamEntry() {
        let wiki = GameEntry(id: "agw:Hollow Knight", name: "Hollow Knight", agwPage: "Hollow Knight",
                             mac: MacTests(crossover: MacTest(rating: .perfect)))
        let steam = GameEntry(id: "steam:367520", name: "Hollow Knight", steam: 367520,
                              store: StoreFacts(macVersion: true, singlePlayer: true, controller: .full, checked: "2026-10-28"))
        let merged = Merge.resolve([steam, wiki], id: "agw:Hollow Knight", steam: 367520)
        XCTAssertEqual(merged.map(\.id), ["steam:367520"])
        XCTAssertEqual(merged.first?.mac?.crossover?.rating, .perfect)
        XCTAssertEqual(merged.first?.store?.controller, .full)
        XCTAssertEqual(merged.first?.agwPage, "Hollow Knight")
        let alone = Merge.resolve([wiki], id: "agw:Hollow Knight", steam: 367520)
        XCTAssertEqual(alone.first?.id, "steam:367520")
        XCTAssertEqual(alone.first?.steam, 367520)
    }

    func testPreviousResolutionIsKept() {
        let previous = list([GameEntry(id: "steam:367520", name: "Hollow Knight", steam: 367520, agwPage: "Hollow Knight")])
        let page = AGWPage(title: "Hollow Knight", steam: nil, tests: MacTests(crossover: MacTest(rating: .perfect)))
        let games = Merge.entries(BuildSources(agw: [page], antiCheat: [], fixes: [], mostPlayed: nil), previous: previous)
        XCTAssertEqual(games.map(\.id), ["steam:367520"])
        XCTAssertEqual(games.first?.mac?.crossover?.rating, .perfect)
    }

    func testCheckRefusesShrunkOrTinyLists() {
        XCTAssertThrowsError(try Merge.check(list(count: 899), previous: list(count: 1000)))
        XCTAssertNoThrow(try Merge.check(list(count: 900), previous: list(count: 1000)))
        XCTAssertThrowsError(try Merge.check(list(count: 499), previous: nil))
        XCTAssertNoThrow(try Merge.check(list(count: 500), previous: nil))
    }

    func testPublishableDropsNamelessAndSorts() {
        let games = Merge.publishable([GameEntry(id: "steam:9", name: "Z"), GameEntry(id: "steam:730", name: ""),
                                       GameEntry(id: "agw:A", name: "A")])
        XCTAssertEqual(games.map(\.id), ["agw:A", "steam:9"])
    }
}
