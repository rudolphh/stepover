import XCTest
@testable import StepoverKit

final class GameFolderTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gamefolder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A small file that starts like a Windows program and holds `marker`.
    @discardableResult
    private func file(_ path: String, _ marker: String = "", windowed: Bool = false) -> URL {
        let url = dir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: 0x200)
        data[0] = 0x4D; data[1] = 0x5A                       // MZ
        data[0x3C] = 0x80                                     // PE header at 0x80
        data.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])
        data[0x84] = 0x64; data[0x85] = 0x86                  // x86-64
        data[0x94] = 0xF0                                     // optional header size
        data[0x98] = 0x0B; data[0x99] = 0x02                  // PE32+
        data[0x98 + 68] = windowed ? 2 : 3                    // subsystem
        data.append(Data(marker.utf8))
        try? data.write(to: url)
        return url
    }

    func testKindsBySignature() {
        XCTAssertEqual(GameFolder.kind(of: file("a/setup.exe", "xx rDlPtS\u{07} yy")), .inno)
        XCTAssertEqual(GameFolder.kind(of: file("b/setup.exe", "NullsoftInst")), .nsis)
        XCTAssertEqual(GameFolder.kind(of: file("c/x.msi")), .msi)
        XCTAssertEqual(GameFolder.kind(of: file("d/setup.exe")), .other)
        XCTAssertNil(GameFolder.kind(of: file("e/TinyGame.exe", windowed: true)))
        // an Inno uninstaller holds Inno's data marker but isn't an installer
        XCTAssertNil(GameFolder.kind(of: file("f/unins000.exe", "Inno Setup Setup Data (6.7.0)")))
    }

    func testInstallerFolderOrder() {
        let inno = "rDlPtS\u{07}"
        file("gog/setup_tiny_gog_-_extra_1.0_(2).exe", inno)
        file("gog/patch_tiny_gog_1.2_(3)_to_1.10_(4).exe", inno)
        file("gog/setup_tiny_gog_1.0_(64bit)_(1).exe", inno)
        file("gog/patch_tiny_gog_1.0_(1)_to_1.2_(3).exe", inno)
        file("gog/readme.txt")
        guard case .install(let installers) = GameFolder.plan(for: dir.appendingPathComponent("gog")) else { return XCTFail() }
        XCTAssertEqual(installers.map(\.url.lastPathComponent), ["setup_tiny_gog_1.0_(64bit)_(1).exe", "setup_tiny_gog_-_extra_1.0_(2).exe",
                                                                 "patch_tiny_gog_1.0_(1)_to_1.2_(3).exe", "patch_tiny_gog_1.2_(3)_to_1.10_(4).exe"])
        XCTAssertEqual(installers.map(\.role), [.base, .addOn, .update, .update])
    }

    func testInstalledGameFolder() {
        file("game/Engine/Binaries/Game.exe", windowed: true)
        file("game/unins000.exe", "Inno Setup Setup Data")
        XCTAssertEqual(GameFolder.plan(for: dir.appendingPathComponent("game")), .installedGame(dir.appendingPathComponent("game")))
    }

    func testSeveralGames() {
        file("parent/A/setup.exe", "rDlPtS\u{07}")
        file("parent/B/setup.exe", "rDlPtS\u{07}")
        XCTAssertEqual(GameFolder.plan(for: dir.appendingPathComponent("parent")),
                       .several([dir.appendingPathComponent("parent/A"), dir.appendingPathComponent("parent/B")]))
        file("wrapper/Game/setup.exe", "rDlPtS\u{07}")
        guard case .install(let installers) = GameFolder.plan(for: dir.appendingPathComponent("wrapper")) else { return XCTFail() }
        XCTAssertEqual(installers.map(\.url), [dir.appendingPathComponent("wrapper/Game/setup.exe")])
    }

    func testArchiveEmptyAndPartial() {
        for name in ["x.zip", "x.rar", "x.7z"] { XCTAssertEqual(GameFolder.plan(for: file(name)), .archive, name) }
        XCTAssertEqual(GameFolder.plan(for: file("x.iso")), .diskImage(dir.appendingPathComponent("x.iso")))
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertEqual(GameFolder.plan(for: dir.appendingPathComponent("empty")), .nothing)
        file("partial/setup.exe", "rDlPtS\u{07}")
        file("partial/setup-1.bin.part")
        XCTAssertEqual(GameFolder.plan(for: dir.appendingPathComponent("partial")), .stillDownloading)
    }

    func testSingleSetupFileBringsItsFolder() {
        let base = file("gog/setup_tiny_gog_1.0_(64bit)_(1).exe", "rDlPtS\u{07}")
        file("gog/setup_tiny_gog_-_extra_1.0_(2).exe", "rDlPtS\u{07}")
        guard case .install(let installers) = GameFolder.plan(for: base) else { return XCTFail() }
        XCTAssertEqual(installers.map(\.url.lastPathComponent), ["setup_tiny_gog_1.0_(64bit)_(1).exe", "setup_tiny_gog_-_extra_1.0_(2).exe"])
    }

    func testLargeAddressAwareCleared() throws {
        var data = try Data(contentsOf: file("laa.exe"))
        data[0x96] = 0x22; data[0x97] = 0x01                  // characteristics 0x0122
        let cleared = try XCTUnwrap(PEFile.clearingLargeAddressAware(data))
        XCTAssertEqual(cleared[0x96], 0x02)
        XCTAssertEqual(cleared[0x97], 0x01)
        XCTAssertEqual(cleared.count, data.count)
        XCTAssertEqual(cleared.prefix(0x96), data.prefix(0x96))
        XCTAssertEqual(cleared.suffix(from: 0x98), data.suffix(from: 0x98))
        XCTAssertNil(PEFile.clearingLargeAddressAware(Data("not a program".utf8)))
    }

    func testWindowedAndProductName() throws {
        guard let runtime = Runtime.installed().first else { throw XCTSkip("no Wine runtime installed") }
        let windows = runtime.url.appendingPathComponent("lib/wine/x86_64-windows")
        XCTAssertEqual(PEFile(url: windows.appendingPathComponent("notepad.exe"))?.isWindowed, true)
        XCTAssertEqual(PEFile(url: windows.appendingPathComponent("cmd.exe"))?.isWindowed, false)
        XCTAssertEqual(PEFile(url: windows.appendingPathComponent("conhost.exe"))?.productName, "Wine")
    }
}
