import XCTest
@testable import StepoverKit

final class SteamStoreTests: XCTestCase {
    // Trimmed from Steam's real answers on 2026-10-28.
    private let rdr2 = Data(#"""
    {"1174180":{"success":true,"data":{"type":"game","name":"Red Dead Redemption 2","steam_appid":1174180,
     "platforms":{"windows":true,"mac":false,"linux":false},
     "categories":[{"id":2,"description":"Single-player"},{"id":1,"description":"Multi-player"},
                   {"id":18,"description":"Partial Controller Support"},{"id":41,"description":"Remote Play on Phone"}]}}}
    """#.utf8)

    private let cyberpunk = Data(#"""
    {"1091500":{"success":true,"data":{"type":"game","name":"Cyberpunk 2077","steam_appid":1091500,
     "platforms":{"windows":true,"mac":true,"linux":false},
     "categories":[{"id":2,"description":"Single-player"},{"id":18,"description":"Partial Controller Support"},
                   {"id":28,"description":"Full controller support"}]}}}
    """#.utf8)

    private let rdr2Deck = Data(#"""
    {"success":1,"results":{"appid":1174180,"resolved_category":2,"resolved_items":[
     {"display_type":3,"loc_token":"#SteamDeckVerified_TestResult_LauncherInteractionIssues"},
     {"display_type":4,"loc_token":"#SteamDeckVerified_TestResult_DefaultControllerConfigFullyFunctional"},
     {"display_type":1,"loc_token":"#SteamDeckVerified_TestResult_FirstTimeSetupRequiresActiveInternetConnection"}]}}
    """#.utf8)

    private let unsupportedDeck = Data(#"""
    {"success":1,"results":{"appid":1172470,"resolved_category":1,"resolved_items":[
     {"display_type":3,"loc_token":"#SteamDeckVerified_TestResult_DefaultControllerConfigFullyFunctional"}]}}
    """#.utf8)

    func testURLs() {
        XCTAssertEqual(SteamStore.appdetailsURL(1174180).absoluteString,
                       "https://store.steampowered.com/api/appdetails?appids=1174180&cc=us&l=en")
        XCTAssertEqual(SteamStore.deckReportURL(1174180).absoluteString,
                       "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=1174180&l=english")
    }

    func testSearchTermDropsSeparators() {
        // Steam's search finds nothing for "Castlevania - Belmont's Curse" (folders write ":" as " - "), but finds
        // "Castlevania: Belmont's Curse" for "Castlevania Belmont's Curse" (2026-10-29)
        func term(_ name: String) -> String? {
            URLComponents(url: SteamStore.searchURL(name), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value
        }
        XCTAssertEqual(term("Castlevania - Belmont's Curse"), "Castlevania Belmont's Curse")
        XCTAssertEqual(term("Batman: Arkham Asylum"), "Batman Arkham Asylum")
        XCTAssertEqual(term("Hollow Knight \u{2013} Silksong"), "Hollow Knight Silksong")
        XCTAssertEqual(term("Half-Life 2"), "Half-Life 2")
        XCTAssertEqual(term("Spider-Man"), "Spider-Man")
    }

    func testStoreFactsRDR2() {
        let r = SteamStore.storeFacts(appdetails: rdr2, appID: 1174180, checked: "2026-10-28")
        XCTAssertEqual(r?.name, "Red Dead Redemption 2")
        XCTAssertEqual(r?.facts, StoreFacts(macVersion: false, singlePlayer: true, controller: .partial, checked: "2026-10-28"))
    }

    func testStoreFactsFullControllerWinsAndMacVersion() {
        let r = SteamStore.storeFacts(appdetails: cyberpunk, appID: 1091500, checked: "2026-10-28")
        XCTAssertEqual(r?.facts.controller, .full)
        XCTAssertEqual(r?.facts.macVersion, true)
    }

    func testStoreFactsNoData() {
        XCTAssertNil(SteamStore.storeFacts(appdetails: Data(#"{"1":{"success":false}}"#.utf8), appID: 1, checked: "2026-10-28"))
        XCTAssertNil(SteamStore.storeFacts(appdetails: Data("<html>".utf8), appID: 1, checked: "2026-10-28"))
        XCTAssertNil(SteamStore.storeFacts(appdetails: rdr2, appID: 99, checked: "2026-10-28"))   // another game's answer
    }

    func testSearchResults() {
        XCTAssertEqual(SteamStore.searchURL("hollow knight").absoluteString,
                       "https://store.steampowered.com/api/storesearch/?term=hollow%20knight&cc=us&l=en")
        let body = Data(#"{"total":2,"items":[{"type":"app","name":"Hollow Knight","id":367520},{"type":"app","name":"Hollow Knight: Silksong","id":1030300}]}"#.utf8)
        XCTAssertEqual(SteamStore.searchResults(body)?.map(\.id), [367520, 1030300])
        XCTAssertEqual(SteamStore.searchResults(body)?.first?.name, "Hollow Knight")
        XCTAssertEqual(SteamStore.searchResults(Data(#"{"total":0,"items":[]}"#.utf8))?.count, 0)
        XCTAssertNil(SteamStore.searchResults(Data("<html>".utf8)))
    }

    // Review M1 (promoted): Steam's placeholder for a delisted game isn't the game's facts.
    func testStoreFactsIgnoresNonGames() {
        let prey = Data(#"{"3970":{"success":true,"data":{"type":"advertising","name":"Prey","steam_appid":3970,"platforms":{"windows":true,"mac":false}}}}"#.utf8)
        XCTAssertNil(SteamStore.storeFacts(appdetails: prey, appID: 3970, checked: "2026-10-28"))
    }

    func testDeckFacts() {
        XCTAssertEqual(SteamStore.deckFacts(report: rdr2Deck, checked: "2026-10-28"),
                       DeckFacts(category: .playable, controllerWorks: true, checked: "2026-10-28"))
        let unsupported = SteamStore.deckFacts(report: unsupportedDeck, checked: "2026-10-28")
        XCTAssertEqual(unsupported?.category, .unsupported)
        XCTAssertEqual(unsupported?.controllerWorks, false)
        XCTAssertNil(SteamStore.deckFacts(report: Data("[]".utf8), checked: "2026-10-28"))
    }
}
