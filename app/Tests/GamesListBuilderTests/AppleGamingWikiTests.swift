import XCTest
@testable import GamesListBuilder

final class AppleGamingWikiTests: XCTestCase {
    // Trimmed from the real pages on 2026-10-28.
    private let rdr2Wikitext = """
    {{Infobox game
    |cover        = Red_Dead_Redemption_2_Cover.jpg
    |steam appid  = 1174180
    |gogcom id    =
    }}
    {{Compatibility/macOS
    |native               = na
    |native notes         = 
    |rosetta 2            = na
    |rosetta 2 notes      = 
    |crossover            = perfect
    |crossover notes      =  only problem is shadows do no render correctly every time.<ref>{{Refdevice|user= Snshahdin|date=May 5th, 2025|device=MacBook Air M3 8GB 8core CPU 8core GPU|os=macOS Sequoia 15.3.1 |method=Crossover 25.0 (25.0.0.38553)|version= latest 1491.50.|store=Steam|framerate=30 FPS|comment= In ESync, RAM didn't leak.}}</ref>
    |wine                 = unplayable
    |wine notes           = 
    |parallels            = unplayable
    |parallels notes      = Unplayable.<ref>{{Refurl|url=https://applesilicongames.com/games/9nfP6gJ5|title=Apple Silicon Games}}</ref>
    }}
    """

    private let eldenRingWikitext = """
    {{Infobox game
    |steam appid  = 1245620
    }}
    {{Compatibility/macOS
    |native               = na
    |crossover            = playable
    |crossover notes      = Launches and runs smoothly. <ref>{{Refdevice|user=Ponkipo|date=2025-05-12|device=MacBook Pro M1 Pro 16 GB|os=MacOS 15.4.1|method=Crossover 23.7.1|version=|comment=Details are in Current Issue}}</ref>
    |wine                 = perfect
    |wine notes           = Requires bypassing Easy Anti-Cheat
    |parallels            = unplayable
    |parallels notes      = Refuses to run.<ref>{{Refdevice|user=Captcool|date=2022-05-31|device=MacBook Pro M1 Max|method=Parallels 17.1.2}}</ref>
    }}
    """

    private let acyJSON = Data(#"""
    [{"name":"Fortnite","slug":"fortnite","status":"Denied","anticheats":["Easy Anti-Cheat"],
      "storeIds":{"epic":{"namespace":"fn","slug":"fortnite"}},"native":false,"url":"https://www.fortnite.com/","notes":[]},
     {"name":"Apex Legends","slug":"apex-legends","status":"Denied","anticheats":["Easy Anti-Cheat","Hyperion"],
      "storeIds":{"steam":"1172470"},"native":false,"url":"https://www.ea.com/games/apex-legends","notes":[]}]
    """#.utf8)

    func testParseRDR2() {
        let page = AppleGamingWiki.parse(title: "Red Dead Redemption 2", wikitext: rdr2Wikitext)
        XCTAssertEqual(page?.title, "Red Dead Redemption 2")
        XCTAssertEqual(page?.steam, 1174180)
        XCTAssertEqual(page?.tests.crossover, MacTest(rating: .perfect, device: "MacBook Air M3 8GB 8core CPU 8core GPU",
                                                      method: "Crossover 25.0", date: "2025-05-05"))
        XCTAssertEqual(page?.tests.wine, MacTest(rating: .unplayable))
        XCTAssertNil(page?.tests.native)                       // "na"
        XCTAssertNil(page?.tests.rosetta)
    }

    func testParseEldenRingTakesOnlyItsOwnMethodsRefdevice() {
        let page = AppleGamingWiki.parse(title: "Elden Ring", wikitext: eldenRingWikitext)
        XCTAssertEqual(page?.tests.crossover?.date, "2025-05-12")
        XCTAssertEqual(page?.tests.crossover?.method, "Crossover 23.7.1")
        XCTAssertEqual(page?.tests.wine, MacTest(rating: .perfect))   // no Refdevice on its notes line
    }

    func testMessyFields() {
        XCTAssertEqual(AppleGamingWiki.parse(title: "X", wikitext: "{{Compatibility/macOS\n|crossover = Perfect <ref>x</ref>\n|wine= unknown\n}}")?
            .tests.crossover?.rating, .perfect)
        XCTAssertNil(AppleGamingWiki.parse(title: "X", wikitext: "{{Compatibility/macOS\n|crossover = Perfect\n}}")?.tests.wine)
        XCTAssertNil(AppleGamingWiki.parse(title: "X", wikitext: "{{Infobox game\n|steam appid = 1\n}}"))
        XCTAssertEqual(AppleGamingWiki.date("May 5th, 2025"), "2025-05-05")
        XCTAssertEqual(AppleGamingWiki.date("2025-05-12"), "2025-05-12")
        XCTAssertEqual(AppleGamingWiki.date("12 March 2024"), "2024-03-12")
        XCTAssertEqual(AppleGamingWiki.date("June 2023"), "2023-06")
        XCTAssertEqual(AppleGamingWiki.date("Sept 3, 2024"), "2024-09-03")
        XCTAssertNil(AppleGamingWiki.date("last week"))
        XCTAssertNil(AppleGamingWiki.date(""))
        XCTAssertEqual(AppleGamingWiki.method(" Crossover 25.0 (25.0.0.38553)"), "Crossover 25.0")
        XCTAssertEqual(AppleGamingWiki.method("Whisky"), "Whisky")
    }

    func testAntiCheatDecode() {
        let games = AntiCheatList.decode(acyJSON)
        XCTAssertEqual(games?.count, 2)
        XCTAssertEqual(games?.first { $0.slug == "fortnite" }?.epic, "fn/fortnite")
        XCTAssertNil(games?.first { $0.slug == "fortnite" }?.steam)
        XCTAssertEqual(games?.first { $0.steam == 1172470 }?.anticheats, ["Easy Anti-Cheat", "Hyperion"])
        XCTAssertEqual(games?.first { $0.steam == 1172470 }?.status, "Denied")
        XCTAssertNil(AntiCheatList.decode(Data("404: Not Found".utf8)))
    }
}
