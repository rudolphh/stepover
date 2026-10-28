import XCTest
@testable import StepoverKit

final class VerdictTests: XCTestCase {
    private func test(_ rating: MacRating, device: String? = nil, method: String? = nil, date: String? = nil) -> MacTest {
        MacTest(rating: rating, device: device, method: method, date: date)
    }

    private func store(mac: Bool = false, single: Bool = true, controller: ControllerCategory? = nil) -> StoreFacts {
        StoreFacts(macVersion: mac, singlePlayer: single, controller: controller, checked: "2026-10-28")
    }

    private func deck(_ category: DeckCategory, controller: Bool = false) -> DeckFacts {
        DeckFacts(category: category, controllerWorks: controller, checked: "2026-10-28")
    }

    private func game(crossover: MacTest? = nil, wine: MacTest? = nil, native: MacTest? = nil, antiCheat: [String]? = nil,
                      store: StoreFacts? = nil, deck: DeckFacts? = nil, fix: Bool = false) -> GameEntry {
        GameEntry(id: "steam:1", name: "Game", steam: 1, mac: MacTests(native: native, crossover: crossover, wine: wine),
                  antiCheat: antiCheat.map { AntiCheat(names: $0, status: "Broken") }, store: store, deck: deck, fix: fix)
    }

    private var rdr2: GameEntry {
        game(crossover: test(.perfect, device: "MacBook Air M3", method: "Crossover 25.0", date: "2025-05-05"),
             wine: test(.unplayable), store: store(controller: .partial), deck: deck(.playable, controller: true), fix: true)
    }
    private var cyberpunk: GameEntry { game(crossover: test(.perfect), native: test(.perfect), store: store(mac: true, controller: .full)) }
    private var duckov: GameEntry { game(store: store(mac: true)) }
    private var old32bit: GameEntry { game(native: test(.unplayable), store: store(mac: true)) }
    private var eldenRing: GameEntry {
        game(crossover: test(.playable), wine: test(.perfect), antiCheat: ["Easy Anti-Cheat"],
             store: store(controller: .full), deck: deck(.verified, controller: true))
    }
    private var apex: GameEntry {
        game(crossover: test(.unplayable), antiCheat: ["Easy Anti-Cheat", "Hyperion"],
             store: store(single: false, controller: .full), deck: deck(.unsupported))
    }
    private var valorant: GameEntry { game(antiCheat: ["Riot Vanguard"]) }
    private var singlePlayerWithAntiCheat: GameEntry { game(antiCheat: ["Denuvo Anti-Cheat"], store: store()) }

    func testYourResultWins() {
        XCTAssertEqual(Verdicts.play(rdr2, yourResult: .runs(minutes: 130)).headline, "Runs on this Mac (you played 2 h)")
        XCTAssertEqual(Verdicts.play(rdr2, yourResult: .runs(minutes: 40)).headline, "Runs on this Mac (you played 40 min)")
        XCTAssertEqual(Verdicts.play(rdr2, yourResult: .problems).headline, "Had problems on this Mac")
        XCTAssertEqual(Verdicts.play(rdr2, yourResult: .problems).kind, .yourProblems)
    }

    func testMacVersion() {
        XCTAssertEqual(Verdicts.play(cyberpunk).headline, "There's a Mac version")
        XCTAssertEqual(Verdicts.play(duckov).headline, "There's a Mac version (not checked on current macOS)")
        XCTAssertNotEqual(Verdicts.play(old32bit).kind, .macVersion)
        XCTAssertTrue(Verdicts.play(old32bit).reasons.contains(
            Reason(text: "The old Mac version doesn't run on current macOS.", source: "AppleGamingWiki")))
        XCTAssertTrue(Verdicts.play(cyberpunk).reasons.contains(Reason(text: "Steam sells a native Mac version.", source: "Steam")))
    }

    func testDoesntRunAndTheOldTestException() {
        XCTAssertEqual(Verdicts.play(game(crossover: test(.unplayable))).headline, "Doesn't run on Mac yet")
        XCTAssertEqual(Verdicts.play(game(crossover: test(.unplayable), wine: test(.unplayable))).kind, .doesntRun)
        let old = game(crossover: test(.unplayable, date: "2022-05-31"), deck: deck(.verified))
        XCTAssertEqual(Verdicts.play(old).headline, "Should play (works on Steam Deck, not tested on Mac yet)")
        XCTAssertEqual(Verdicts.play(old).reasons.first, Reason(text: "An older Mac test (2022) didn't run.", source: "AppleGamingWiki, May 2022"))
        // without a good Steam Deck result the old test still counts
        XCTAssertEqual(Verdicts.play(game(crossover: test(.unplayable, date: "2022-05-31"))).kind, .doesntRun)
    }

    func testAntiCheat() {
        XCTAssertEqual(Verdicts.play(eldenRing).headline, "Plays great (tested on Mac)")
        XCTAssertEqual(Verdicts.play(eldenRing).extra, ["Single-player only: online play needs anti-cheat that doesn't work on Mac"])
        XCTAssertEqual(Verdicts.play(apex).headline, "Doesn't run on Mac yet")      // rule 3 comes first
        XCTAssertTrue(Verdicts.play(apex).reasons.contains(
            Reason(text: "Uses Easy Anti-Cheat and Hyperion, which don't work on Mac.", source: "AreWeAntiCheatYet")))
        XCTAssertEqual(Verdicts.play(valorant).headline, "Won't run: needs anti-cheat that doesn't work on Mac")
        XCTAssertEqual(Verdicts.play(valorant).kind, .antiCheatBlocked)
        XCTAssertEqual(Verdicts.play(singlePlayerWithAntiCheat).kind, .singlePlayerOnly)
        XCTAssertEqual(Verdicts.play(singlePlayerWithAntiCheat).headline,
                       "Single-player only: online play needs anti-cheat that doesn't work on Mac")
    }

    func testTestedOnMacAndReasons() {
        let v = Verdicts.play(rdr2)
        XCTAssertEqual(v.headline, "Plays great (tested on Mac)")
        XCTAssertEqual(v.kind, .playsGreat)
        XCTAssertEqual(v.reasons.first, Reason(text: "Tested with CrossOver 25.0 on MacBook Air M3: perfect.", source: "AppleGamingWiki, May 2025"))
        XCTAssertTrue(v.reasons.contains(Reason(text: "Tested with Wine: doesn't run.", source: "AppleGamingWiki")))
        XCTAssertTrue(v.reasons.contains(Reason(text: "Steam Deck: Playable.", source: "Valve")))
        XCTAssertEqual(v.extra, ["Stepover applies a fix for this game automatically"])
        XCTAssertEqual(Verdicts.play(game(wine: test(.playable))).headline, "Playable (tested on Mac)")
        XCTAssertEqual(Verdicts.play(game(crossover: test(.runs))).headline, "Starts, with problems (tested on Mac)")
    }

    // Review I5: a tester's free-text method only shows when it reads like a product and version.
    func testMethodCopy() {
        func first(_ method: String) -> String? { Verdicts.play(game(crossover: test(.perfect, method: method))).reasons.first?.text }
        XCTAssertEqual(first("Installed through Steam."), "Tested with CrossOver: perfect.")
        XCTAssertEqual(first("Crossover 23.6 D3DMetal enabled"), "Tested with CrossOver: perfect.")
        XCTAssertEqual(first("Whisky+PortingKit"), "Tested with CrossOver: perfect.")
        XCTAssertEqual(first("crossover 24.0.1"), "Tested with CrossOver 24.0.1: perfect.")
        XCTAssertEqual(first("Whisky 2.3"), "Tested with Whisky 2.3: perfect.")
    }

    // Review I4: a bad stored date gives the plain source, never another month.
    func testImpossibleMonthGivesPlainSource() {
        XCTAssertEqual(Verdicts.play(game(crossover: test(.perfect, date: "2021-24-10"))).reasons.first?.source, "AppleGamingWiki")
    }

    func testLinuxEvidenceAndNothing() {
        XCTAssertEqual(Verdicts.play(game(deck: deck(.playable))).kind, .shouldPlay)
        XCTAssertEqual(Verdicts.play(game(deck: deck(.unsupported))).headline, "Probably won't run")
        XCTAssertEqual(Verdicts.play(game()).headline, "Not tested yet. Try it; Stepover will remember how it went.")
        XCTAssertEqual(Verdicts.play(nil).headline, "Not tested yet. Try it; Stepover will remember how it went.")
        XCTAssertEqual(Verdicts.play(nil).reasons, [])
    }

    func testController() {
        XCTAssertEqual(Verdicts.controller(rdr2), .worksMenusMouse)
        XCTAssertEqual(Verdicts.controller(rdr2)?.rawValue, "Controller works; some menus may need a mouse")
        XCTAssertEqual(Verdicts.controller(eldenRing), .full)
        XCTAssertEqual(Verdicts.controller(game(store: store(controller: .partial))), .partial)
        XCTAssertEqual(Verdicts.controller(duckov), .keyboardMouse)
        XCTAssertNil(Verdicts.controller(valorant))
        XCTAssertNil(Verdicts.controller(nil))
        XCTAssertEqual(Verdicts.controller(duckov, playedWithController: true), .yours)
    }
}
