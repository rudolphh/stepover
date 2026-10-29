import XCTest
@testable import StepoverKit

/// Listings from the games installed on the maintainer's Mac (sizes as found; installer leftovers left out).
final class GameFinderTests: XCTestCase {
    private func exe(_ path: String, _ size: Int64, windowed: Bool = true, graphics: Bool = false, shortcut: Bool = false) -> ExeCandidate {
        ExeCandidate(path: path, size: size, windowed: windowed, graphics: graphics, fromShortcut: shortcut)
    }

    private var rdr2: [ExeCandidate] {
        [exe("RDR2.exe", 89_849_752, graphics: true), exe("PlayRDR2.exe", 421_816), exe("Launcher.exe", 140_288),
         exe("Uninstall/unins000.exe", 3_000_000), exe("x64/crashpad/release/crashpad_handler.exe", 1_000_000, windowed: false)]
    }

    func testRedDead() {
        XCTAssertEqual(GameFinder.rank(rdr2, gameName: "Red Dead Redemption 2", knownExes: ["RDR2.exe"]).first?.path, "RDR2.exe")
        XCTAssertEqual(GameFinder.rank(rdr2, gameName: "Red Dead Redemption 2", knownExes: []).first?.path, "RDR2.exe")
    }

    func testHiFiRush() {
        let listing = [exe("Hi-Fi-RUSH.exe", 197_632), exe("Hibiki/Binaries/Win64/Hi-Fi-RUSH.exe", 70_752_768, graphics: true),
                       exe("Uninstall/unins000.exe", 3_000_000), exe("Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe", 20_000_000)]
        XCTAssertEqual(GameFinder.rank(listing, gameName: "Hi-Fi RUSH", knownExes: []).first?.path, "Hi-Fi-RUSH.exe")
    }

    func testIAmJesusChrist() {
        let listing = [exe("unins000.exe", 3_000_000), exe("IMJCH.exe", 366_080), exe("_Redist/vc_redist.x86.exe", 13_000_000),
                       exe("_Redist/dxwebsetup.exe", 300_000), exe("_Redist/vc_redist.x64.exe", 24_000_000),
                       exe("_Redist/QuickSFV.EXE", 100_000), exe("IMJCH/Binaries/Win64/IMJCH-Win64-Shipping.exe", 161_986_120, graphics: true)]
        XCTAssertEqual(GameFinder.rank(listing, gameName: "I Am Jesus Christ", knownExes: []).first?.path, "IMJCH.exe")
    }

    func testSainthood() {
        let listing = [exe("Sainthood.exe", 666_624), exe("unins000.exe", 3_000_000), exe("UnityCrashHandler64.exe", 1_500_000),
                       exe("_Redist/dxwebsetup.exe", 300_000), exe("_Redist/QuickSFV.EXE", 100_000)]
        XCTAssertEqual(GameFinder.rank(listing, gameName: "Sainthood", knownExes: []).first?.path, "Sainthood.exe")
    }

    func testDuckov() {
        let listing = [exe("Duckov.exe", 650_000), exe("UnityCrashHandler64.exe", 1_500_000), exe("unins000.exe", 3_000_000)]
        XCTAssertEqual(GameFinder.rank(listing, gameName: "Escape from Duckov", knownExes: []).first?.path, "Duckov.exe")
    }

    func testAShortcutBeatsSize() {
        let listing = [exe("bin/Game.exe", 50_000_000, graphics: true), exe("Start.exe", 300_000, shortcut: true)]
        XCTAssertEqual(GameFinder.rank(listing, gameName: "Something Else", knownExes: []).first?.path, "Start.exe")
    }

    func testNothingLeft() {
        XCTAssertEqual(GameFinder.rank([exe("unins000.exe", 3_000_000), exe("vc_redist.x64.exe", 24_000_000),
                                        exe("tool.exe", 9_000, windowed: false)], gameName: "X", knownExes: []), [])
    }

    func testCandidatesReadsFolder() throws {
        guard let runtime = Runtime.installed().first else { throw XCTSkip("no Wine runtime installed") }
        let windows = runtime.url.appendingPathComponent("lib/wine/x86_64-windows")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("finder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: windows.appendingPathComponent("notepad.exe"), to: folder.appendingPathComponent("Game.exe"))
        try FileManager.default.copyItem(at: windows.appendingPathComponent("cmd.exe"), to: folder.appendingPathComponent("bin/tool.exe"))
        let found = GameFinder.candidates(in: folder, shortcuts: [#"C:\Games\Game\Game.exe"#])
        XCTAssertEqual(found.map(\.path).sorted(), ["Game.exe", "bin/tool.exe"])
        XCTAssertEqual(found.first { $0.path == "Game.exe" }?.windowed, true)
        XCTAssertEqual(found.first { $0.path == "Game.exe" }?.fromShortcut, true)
        XCTAssertEqual(found.first { $0.path == "bin/tool.exe" }?.windowed, false)
    }

    func testComponents() {
        XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx11_43.dll", "d3dcompiler_43.dll"], shipped: []), ["d3dcompiler_43", "d3dx11_43"])
        XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx9_43.dll"], shipped: []), ["d3dx9"])
        XCTAssertEqual(NeededComponents.verbs(imports: ["xactengine3_7.dll", "x3daudio1_7.dll"], shipped: []), ["xact"])
        XCTAssertEqual(NeededComponents.verbs(imports: ["msvcp140.dll", "vcruntime140.dll"], shipped: []), [])
        XCTAssertEqual(NeededComponents.verbs(imports: ["d3dx9_43.dll"], shipped: ["d3dx9_43.dll"]), [])
        XCTAssertEqual(NeededComponents.verbs(imports: ["PhysXLoader.dll"], shipped: []), ["physx"])
        XCTAssertTrue(NeededComponents.shipsDLSS(["nvngx_dlss.dll"]))
        XCTAssertFalse(NeededComponents.shipsDLSS(["d3d11.dll"]))
    }
}
