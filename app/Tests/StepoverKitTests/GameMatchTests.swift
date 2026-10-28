import XCTest
@testable import StepoverKit

final class GameMatchTests: XCTestCase {
    private func entry(_ id: String, _ name: String, names: [String] = [], exes: [String] = []) -> GameEntry {
        GameEntry(id: id, name: name, names: names, steam: Int(id.split(separator: ":").last ?? ""), exes: exes)
    }

    private func list(_ games: [GameEntry]) -> GamesList {
        GamesList(format: 1, generated: "", credits: [], games: games)
    }

    func testNormalized() {
        XCTAssertEqual(GameName.normalized("Hi-Fi RUSH"), "hi fi rush")
        XCTAssertEqual(GameName.normalized("Apex Legends™"), "apex legends")
        XCTAssertEqual(GameName.normalized("The Witcher 3: Wild Hunt – Game of the Year Edition"), "the witcher 3 wild hunt")
        XCTAssertEqual(GameName.normalized("Pokémon & Friends"), "pokemon and friends")
        XCTAssertEqual(GameName.normalized("  ELDEN RING  "), "elden ring")
    }

    func testMatchByExeThenName() {
        let index = GameIndex(list([entry("steam:1174180", "Red Dead Redemption 2", exes: ["RDR2.exe"]),
                                    entry("steam:1817230", "Hi-Fi RUSH", names: ["HI-Fi RUSH"])]))
        XCTAssertEqual(index.match(name: "RDR2", exe: "rdr2.EXE")?.steam, 1174180)
        XCTAssertEqual(index.match(name: "Hi-Fi Rush", exe: "Launcher.exe")?.steam, 1817230)
        XCTAssertEqual(index.match(name: "HI-FI RUSH", exe: nil)?.steam, 1817230)
        XCTAssertEqual(index.entry(steam: 1817230)?.name, "Hi-Fi RUSH")
        XCTAssertNil(index.entry(steam: 1))
    }

    func testNoMatchRatherThanWrongGame() {
        let index = GameIndex(list([entry("steam:55230", "Saints Row: The Third"),
                                    entry("steam:2050650", "Resident Evil 4"), entry("steam:254700", "Resident Evil 4")]))
        XCTAssertNil(index.match(name: "Sainthood", exe: "Sainthood.exe"))
        XCTAssertNil(index.match(name: "Resident Evil 4", exe: nil))   // two games share the name
    }
}
