import XCTest
@testable import StepoverKit

final class LibraryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func bottle(_ name: String) -> Bottle {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        return Bottle(url: url)
    }

    private func config(_ programs: [Program]) -> BottleConfig { BottleConfig(programs: programs) }

    private let rdr2Folder = #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2"#

    private var index: GameIndex {
        GameIndex(GamesList(format: 1, generated: "", credits: [], games: [
            GameEntry(id: "steam:1174180", name: "Red Dead Redemption 2", steam: 1174180, exes: ["RDR2.exe"],
                      mac: MacTests(crossover: MacTest(rating: .perfect))),
            GameEntry(id: "steam:1817230", name: "Hi-Fi RUSH", steam: 1817230),
        ]))
    }

    private func setup() -> (bottles: [(bottle: Bottle, config: BottleConfig)], steamApps: (Bottle) -> [SteamApp]) {
        let steam = bottle("Steam"), sainthood = bottle("Sainthood")
        let rdr2 = SteamApp(id: 1174180, name: "Red Dead Redemption 2", folder: steam.url.appendingPathComponent("rdr2"),
                            windowsFolder: rdr2Folder)
        return ([(steam, config([Program(name: "Steam", exe: #"C:\Program Files (x86)\Steam\steam.exe"#),
                                 Program(name: "RDR2 launcher", exe: rdr2Folder + #"\RDR2.exe"#)])),
                 (sainthood, config([Program(name: "Sainthood", exe: #"C:\Games\Sainthood\Sainthood.exe"#)]))],
                { $0.name == "Steam" ? [rdr2] : [] })
    }

    func testProgramsSteamGamesAndTheClient() {
        let (bottles, steamApps) = setup()
        let games = Library.games(bottles: bottles, steamApps: steamApps, index: index, recent: [])
        XCTAssertEqual(games.map(\.name), ["Red Dead Redemption 2", "Sainthood", "Steam"])
        XCTAssertEqual(games[0].steamAppID, 1174180)
        XCTAssertEqual(games[0].launch.args, ["-applaunch", "1174180"])
        XCTAssertEqual(games[0].launch.name, "Red Dead Redemption 2")
        XCTAssertEqual(games[0].launch.exe, #"C:\Program Files (x86)\Steam\steam.exe"#)
        XCTAssertEqual(games[0].entry?.steam, 1174180)
        XCTAssertNil(games[1].entry)                      // nothing in the list is named Sainthood
        XCTAssertNil(games[1].steamAppID)
        if case .steamClient = games[2].kind {} else { XCTFail("the Steam program is the client tile") }
        XCTAssertNil(games[2].entry)
        XCTAssertEqual(Set(games.map(\.id)).count, 3)
    }

    func testRecentlyPlayedFirst() {
        let (bottles, steamApps) = setup()
        let recent = [RecentGames.Entry(bottle: "Sainthood", program: "Sainthood", played: Date().addingTimeInterval(-86400))]
        let games = Library.games(bottles: bottles, steamApps: steamApps, index: index, recent: recent)
        XCTAssertEqual(games.map(\.name), ["Sainthood", "Red Dead Redemption 2", "Steam"])
        XCTAssertNotNil(games[0].lastPlayed)
    }

    func testMatchFallsBackToTheBottleName() {
        let hifi = bottle("Hi-Fi RUSH")
        let games = Library.games(bottles: [(hifi, config([Program(name: "Launcher", exe: #"C:\Games\HiFi\Launcher.exe"#)]))],
                                  steamApps: { _ in [] }, index: index, recent: [])
        XCTAssertEqual(games.first?.entry?.steam, 1817230)
        XCTAssertEqual(games.first?.name, "Launcher")
    }

    func testSteamClientFromTheInstallWhenNoProgram() throws {
        let steam = bottle("Steam")
        let exe = steam.cDrive.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: exe)
        XCTAssertEqual(SteamLibrary.client(in: steam)?.exe, #"C:\Program Files (x86)\Steam\steam.exe"#)
        let games = Library.games(bottles: [(steam, config([]))], steamApps: { _ in [] }, index: index, recent: [])
        XCTAssertEqual(games.map(\.name), ["Steam"])
        XCTAssertNil(SteamLibrary.client(in: bottle("Empty")))
    }

    // Review M10/M11/M12: the Steam program's own settings carry into -applaunch; without a client, a program in
    // a Steam game's folder stays a tile; Steam's redistributables are not a game.
    func testSteamLaunchKeepsTheClientsSettingsAndRedistributablesAreSkipped() {
        let steam = bottle("Steam")
        let client = Program(name: "Steam", exe: #"C:\Program Files (x86)\Steam\steam.exe"#, args: ["-silent"], env: ["X": "1"])
        let redist = SteamApp(id: 228980, name: "Steamworks Common Redistributables", folder: steam.url, windowsFolder: #"C:\x\common\Steamworks Shared"#)
        let rdr2 = SteamApp(id: 1174180, name: "Red Dead Redemption 2", folder: steam.url, windowsFolder: rdr2Folder)
        let games = Library.games(bottles: [(steam, config([client]))], steamApps: { _ in [redist, rdr2] }, index: index, recent: [])
        XCTAssertEqual(games.map(\.name), ["Red Dead Redemption 2", "Steam"])
        XCTAssertEqual(games[0].launch.args, ["-silent", "-applaunch", "1174180"])
        XCTAssertEqual(games[0].launch.env, ["X": "1"])

        let odd = bottle("Odd Steam")   // Steam somewhere Stepover can't find: the launcher stays
        let launcher = Program(name: "RDR2 launcher", exe: rdr2Folder + #"\RDR2.exe"#)
        let kept = Library.games(bottles: [(odd, config([launcher]))], steamApps: { _ in [rdr2] }, index: index, recent: [])
        XCTAssertEqual(kept.map(\.name), ["RDR2 launcher"])
    }

    func testShortCopyAndTone() {
        XCTAssertEqual(PlayVerdict.Kind.antiCheatBlocked.short, "Won't run: anti-cheat")
        XCTAssertEqual(PlayVerdict.Kind.notTested.short, "Not tested yet")
        XCTAssertEqual(PlayVerdict.Kind.playsGreat.tone, .good)
        XCTAssertEqual(PlayVerdict.Kind.macVersion.tone, .mac)
        XCTAssertEqual(PlayVerdict.Kind.doesntRun.tone, .bad)
        XCTAssertEqual(ControllerVerdict.worksMenusMouse.short, "Controller, mouse for menus")
        XCTAssertEqual(ControllerVerdict.full.short, "Full controller")
    }

    // Review I5: every tone's text reads at 4.5:1 on its own pill, in light and dark windows.
    func testToneContrast() {
        let light = TileTone.windowBackground(dark: false), dark = TileTone.windowBackground(dark: true)
        for tone in [TileTone.good, .maybe, .caution, .bad, .mac, .unknown] {
            for (isDark, window) in [(false, light), (true, dark)] {
                let text = tone.rgb(dark: isDark)
                let pill = TileTone.blend(text, over: window, alpha: tone.pillAlpha)
                XCTAssertGreaterThanOrEqual(TileTone.contrast(text, pill), 4.5, "\(tone) \(isDark ? "dark" : "light")")
            }
        }
    }

    func testHiddenGamesSurviveASave() throws {
        let file = dir.appendingPathComponent("library.json")
        XCTAssertEqual(LibraryState.load(from: file).hidden, [])
        try LibraryState(hidden: ["x|Steam"]).save(to: file)
        XCTAssertEqual(LibraryState.load(from: file).hidden, ["x|Steam"])
        try Data("{".utf8).write(to: file)
        XCTAssertEqual(LibraryState.load(from: file).hidden, [])
    }
}
