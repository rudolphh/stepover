import XCTest
@testable import StepoverKit

final class AddGameNameTests: XCTestCase {
    func testCleanNames() {
        let cases = [
            "Escape from Duckov [Group Repack]": "Escape from Duckov",
            "Red.Dead.Redemption.2.Build.1436.28-GROUP": "Red Dead Redemption 2",
            "The.Witcher.3.Wild.Hunt.GOTY.v4.04-GROUP": "The Witcher 3 Wild Hunt GOTY",
            "Marvels.Spider-Man.Remastered-GROUP": "Marvels Spider-Man Remastered",
            "Spider-Man": "Spider-Man", "Half-Life 2": "Half-Life 2", "Hi Fi Rush": "Hi Fi Rush",
            "Sainthood v1.0.3 (64-bit)": "Sainthood",
            "setup_i_am_jesus_christ_1.0.2_(64bit)_(81234).exe": "i am jesus christ",
            "Game_Name_x64_Installer": "Game Name", "Tiny.Game.v1.0.2-GROUP": "Tiny Game",
        ]
        for (raw, clean) in cases { XCTAssertEqual(FolderName.clean(raw), clean, raw) }
    }

    private let index = GameIndex(GamesList(format: 1, generated: "", credits: [], games: [
        GameEntry(id: "steam:1817230", name: "Hi-Fi RUSH", steam: 1817230),
        GameEntry(id: "steam:1", name: "Shooter", steam: 1, antiCheat: AntiCheat(names: ["Easy Anti-Cheat"], status: "Denied"),
                  store: StoreFacts(macVersion: false, singlePlayer: false, controller: nil, checked: "2026-10-28")),
        GameEntry(id: "steam:2", name: "Campaign", steam: 2, antiCheat: AntiCheat(names: ["Easy Anti-Cheat"], status: "Denied"),
                  store: StoreFacts(macVersion: false, singlePlayer: true, controller: nil, checked: "2026-10-28")),
    ]))

    func testRecognizeTriesEachCandidate() {
        let found = Recognize.game(candidates: ["Some Folder", "Hi Fi Rush"], index: index, learned: nil)
        XCTAssertEqual(found.name, "Hi-Fi RUSH")
        XCTAssertEqual(found.entry?.id, "steam:1817230")
    }

    func testRecognizeUsesLearnedGames() {
        let learned = GameIndex(GamesList(format: 1, generated: "", credits: [], games: [GameEntry(id: "steam:9", name: "Tiny Game", steam: 9)]))
        XCTAssertEqual(Recognize.game(candidates: ["Tiny Game"], index: index, learned: learned).entry?.id, "steam:9")
    }

    func testRecognizeUnknownKeepsFirstName() {
        XCTAssertEqual(Recognize.game(candidates: ["", "Tiny Game", "Other"], index: index, learned: nil),
                       Recognized(name: "Tiny Game", entry: nil))
    }

    func testConfirmationOnlyForTheFirmNo() {
        XCTAssertTrue(Recognize.needsConfirmation(index.match(name: "Shooter", exe: nil)))
        XCTAssertFalse(Recognize.needsConfirmation(index.match(name: "Campaign", exe: nil)))
        XCTAssertFalse(Recognize.needsConfirmation(nil))
    }

    func testExistingByEntryThenName() {
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/stepover-tests/Hi-Fi Rush"))
        let program = Program(name: "Hi-Fi Rush", exe: #"C:\Games\Hi-Fi Rush\Hi-Fi-RUSH.exe"#)
        let tile = LibraryGame(id: "\(bottle.id)|Hi-Fi Rush", name: "Hi-Fi Rush", bottle: bottle, kind: .program(program),
                               entry: index.entry(steam: 1817230), lastPlayed: nil, steamAppID: 1817230, launch: program)
        let unknown = Program(name: "Tiny Game", exe: #"C:\Games\Tiny Game\TinyGame.exe"#)
        let tiny = LibraryGame(id: "x|Tiny Game", name: "Tiny Game", bottle: bottle, kind: .program(unknown),
                               entry: nil, lastPlayed: nil, steamAppID: nil, launch: unknown)
        XCTAssertEqual(Recognize.existing(Recognized(name: "Hi-Fi RUSH", entry: index.entry(steam: 1817230)), in: [tiny, tile])?.id, tile.id)
        XCTAssertEqual(Recognize.existing(Recognized(name: "tiny game", entry: nil), in: [tile, tiny])?.id, tiny.id)
        XCTAssertNil(Recognize.existing(Recognized(name: "Other", entry: nil), in: [tile, tiny]))
    }
}
