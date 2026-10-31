import XCTest
@testable import StepoverKit

final class AroundInstallTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUp() {
        dir = fm.temporaryDirectory.appendingPathComponent("around-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: dir) }

    @discardableResult
    private func write(_ path: String, _ text: String) -> URL {
        let url = dir.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    private func age(_ path: String, seconds: Double, now: Date) {
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-seconds)], ofItemAtPath: dir.appendingPathComponent(path).path)
    }

    func testChecksums() {
        XCTAssertNil(ChecksumCheck.damaged(in: dir))
        write("game/setup-1.bin", "hello")
        write("game/setup-2.bin", "hello")
        write("game/MD5/group-bins.md5", "; checksums\n5d41402abc4b2a76b9719d911017c592 *..\\setup-1.bin\n5d41402abc4b2a76b9719d911017c592 *..\\setup-2.bin\n")
        XCTAssertEqual(ChecksumCheck.damaged(in: dir.appendingPathComponent("game")), 0)
        write("game/setup-2.bin", "hellO")
        XCTAssertEqual(ChecksumCheck.damaged(in: dir.appendingPathComponent("game")), 1)
        try? fm.removeItem(at: dir.appendingPathComponent("game/setup-1.bin"))
        XCTAssertEqual(ChecksumCheck.damaged(in: dir.appendingPathComponent("game")), 2)

        write("sfv/a.bin", "hello")
        write("sfv/files.sfv", "; made by a tool\na.bin 3610A686\n")
        XCTAssertEqual(ChecksumCheck.damaged(in: dir.appendingPathComponent("sfv")), 0)
        write("sfv/a.bin", "jello")
        XCTAssertEqual(ChecksumCheck.damaged(in: dir.appendingPathComponent("sfv")), 1)
    }

    func testDownloadsList() {
        let now = Date()
        let inno = "MZ rDlPtS\u{07}"
        write("Old Game/setup.exe", inno); age("Old Game/setup.exe", seconds: 3 * 86_400, now: now); age("Old Game", seconds: 3 * 86_400, now: now)
        write("New Game/setup.exe", inno); age("New Game/setup.exe", seconds: 86_400, now: now); age("New Game", seconds: 86_400, now: now)
        write("Busy/setup.exe", inno); write("Busy/setup-1.bin.part", "x")
        age("Busy/setup.exe", seconds: 86_400, now: now); age("Busy/setup-1.bin.part", seconds: 86_400, now: now)
        write("notes.txt", "hi"); age("notes.txt", seconds: 100, now: now)
        write("x.iso", "iso"); age("x.iso", seconds: 2 * 86_400, now: now)
        XCTAssertEqual(DownloadsScan.candidates(in: dir, now: now).map(\.lastPathComponent), ["New Game", "x.iso", "Old Game"])
        age("Old Game/setup.exe", seconds: 10, now: now)
        XCTAssertEqual(DownloadsScan.candidates(in: dir, now: now).map(\.lastPathComponent), ["New Game", "x.iso"])
    }

    func testFolderStillChanging() {
        let now = Date()
        write("copying/Game/data.bin", "x"); age("copying/Game/data.bin", seconds: 3_600, now: now)
        write("copying/setup.exe", "x"); age("copying/setup.exe", seconds: 3_600, now: now)
        age("copying/Game", seconds: 3_600, now: now); age("copying", seconds: 3_600, now: now)
        XCTAssertFalse(GameFolder.isChanging(dir.appendingPathComponent("copying"), now: now))
        age("copying/Game/data.bin", seconds: 20, now: now)          // a file two levels down still being written
        XCTAssertTrue(GameFolder.isChanging(dir.appendingPathComponent("copying"), now: now))
        // a dropped file: only the file itself (it may sit in a busy Downloads folder)
        XCTAssertFalse(GameFolder.isChanging(dir.appendingPathComponent("copying/setup.exe"), now: now))
        age("copying/setup.exe", seconds: 10, now: now)
        XCTAssertTrue(GameFolder.isChanging(dir.appendingPathComponent("copying/setup.exe"), now: now))
    }

    func testPublicDownloadsFolder() throws {
        // Windows makes C:\users\Public\Downloads at setup; Wine doesn't, and Rockstar's launcher service
        // fails without it (FOLDERID_PublicDownloads).
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        try fm.createDirectory(at: bottle.cDrive.appendingPathComponent("users/Public/Documents"), withIntermediateDirectories: true)
        try BottleSetup.makePublicDownloads(bottle)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: bottle.cDrive.appendingPathComponent("users/Public/Downloads").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try BottleSetup.makePublicDownloads(bottle)   // again: already there is fine
    }

    func testLaunchMakesPublicDownloadsInOlderBottles() throws {
        setenv("STEPOVER_FIXES", dir.appendingPathComponent("fixes").path, 1)
        setenv("STEPOVER_LOGS", dir.appendingPathComponent("logs").path, 1)
        defer { unsetenv("STEPOVER_FIXES"); unsetenv("STEPOVER_LOGS") }
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        try fm.createDirectory(at: bottle.cDrive.appendingPathComponent("users/Public/Documents"), withIntermediateDirectories: true)
        try Launcher.prepare(bottle: bottle, config: BottleConfig(), runtime: Runtime(url: dir.appendingPathComponent("runtime")))
        XCTAssertTrue(fm.fileExists(atPath: bottle.cDrive.appendingPathComponent("users/Public/Downloads").path))
    }

    func testNGXPathForMetalFX() throws {
        // DLSS on MetalFX finds nvngx.dll through NGXCore's FullPath; CrossOver bottles carry it, new bottles don't.
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        write("bottle/system.reg", "WINE REGISTRY Version 2\n\n[Software\\\\Nvidia Corporation\\\\Global\\\\NGXCore] 1793335434\n#time=1dd6\n\n")
        let patch = try XCTUnwrap(BottleSetup.ngxPathPatch(bottle))
        XCTAssertTrue(patch.text.contains("[HKEY_LOCAL_MACHINE\\Software\\NVIDIA Corporation\\Global\\NGXCore]\r\n\"FullPath\"=\"C:\\\\windows\\\\system32\"\r\n"), patch.text)
        write("bottle/system.reg", "WINE REGISTRY Version 2\n\n[Software\\\\Nvidia Corporation\\\\Global\\\\NGXCore] 1792659227\n\"FullPath\"=\"C:\\\\windows\\\\system32\"\n\n")
        XCTAssertNil(BottleSetup.ngxPathPatch(bottle))
    }

    func testGTAEnhancedIsMarkedDPIAwareUnlessTheBottleSaysOtherwise() throws {
        // At 192 DPI GTA V Enhanced draws itself twice its size; Windows' compatibility mark HIGHDPIAWARE (which Wine
        // reads by lowercased file name) makes it fill the screen, and at 96 DPI it changes nothing.
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        write("bottle/user.reg", "WINE REGISTRY Version 2\n\n[Control Panel\\\\Desktop] 1793335434\n\"LogPixels\"=dword:000000c0\n\n")
        let patch = try XCTUnwrap(BottleSetup.compatLayersPatch(bottle, builtInFixes: true))
        XCTAssertTrue(patch.text.contains("[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers]\r\n"
            + "\"gta5_enhanced.exe\"=\"~ HIGHDPIAWARE\"\r\n"), patch.text)
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: false), "a bottle with built-in fixes off gets none")
        write("bottle/user.reg", "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\AppCompatFlags\\\\Layers] 1793385908\n"
            + "#time=1dd689ec938c872\n\"GTA5_Enhanced.exe\"=\"~ DPIUNAWARE\"\n\n")
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: true), "the bottle's own mark for the game wins")
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: false), "turning built-in fixes off leaves the bottle's own mark")
    }

    func testBuiltInMarkLeavesMarksWineReadsFirstOrForEveryProgram() {
        // Wine reads HKCU's mark, then HKLM's, and a key's default value covers every program without a mark of its own.
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        let layers = "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\AppCompatFlags\\\\Layers] 1793385908\n"
        write("bottle/system.reg", "WINE REGISTRY Version 2\n\n" + layers + "\"gta5_enhanced.exe\"=\"~ DPIUNAWARE\"\n\n")
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: true), "a mark in HKLM")
        write("bottle/system.reg", "WINE REGISTRY Version 2\n\n")
        write("bottle/user.reg", "WINE REGISTRY Version 2\n\n" + layers + "@=\"~ DPIUNAWARE\"\n\n")
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: true), "a default mark in HKCU")
    }

    func testTurningBuiltInFixesOffRemovesStepoversMark() throws {
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        write("bottle/user.reg", "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\AppCompatFlags\\\\Layers] 1793385908\n"
            + "\"gta5_enhanced.exe\"=\"~ HIGHDPIAWARE\"\n\n")
        XCTAssertNil(BottleSetup.compatLayersPatch(bottle, builtInFixes: true), "already there")
        let patch = try XCTUnwrap(BottleSetup.compatLayersPatch(bottle, builtInFixes: false))
        XCTAssertTrue(patch.text.contains("\"gta5_enhanced.exe\"=-\r\n"), patch.text)
    }

    func testLaunchRegistryChangesGoTogetherAndOnlyNGXCoreWaits() throws {
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        write("bottle/system.reg", "WINE REGISTRY Version 2\n\n")
        write("bottle/user.reg", "WINE REGISTRY Version 2\n\n")
        let both = try XCTUnwrap(Launcher.registryChanges(bottle, config: BottleConfig(), metalFX: true))
        XCTAssertTrue(both.patch.text.contains("\"FullPath\"=\"C:\\\\windows\\\\system32\""), both.patch.text)
        XCTAssertTrue(both.patch.text.contains("\"gta5_enhanced.exe\"=\"~ HIGHDPIAWARE\""), both.patch.text)
        XCTAssertEqual(both.done, ["MetalFX: set NGXCore FullPath so games find nvngx.dll",
                                   "built-in fixes: set compatibility marks for gta5_enhanced.exe"])
        XCTAssertTrue(both.waitForIdle)
        let marks = try XCTUnwrap(Launcher.registryChanges(bottle, config: BottleConfig(), metalFX: false))
        XCTAssertFalse(marks.patch.text.contains("FullPath"))
        XCTAssertFalse(marks.waitForIdle, "a mark waits for the next launch into an idle bottle instead")
        var off = BottleConfig()
        off.builtInFixes = false
        XCTAssertNil(Launcher.registryChanges(bottle, config: off, metalFX: false))
    }

    func testMetalFXIsOnForTheBottleOrOneOfItsPrograms() {
        var config = BottleConfig()
        XCTAssertFalse(Launcher.metalFX(config, fixes: []))
        config.processes = ["GTA5_Enhanced.exe": ProcessRule(env: ["D3DM_ENABLE_METALFX": "1"])]
        XCTAssertTrue(Launcher.metalFX(config, fixes: []))
        XCTAssertTrue(Launcher.metalFX(BottleConfig(env: ["D3DM_ENABLE_METALFX": "1"]), fixes: []))
    }

    func testDXMTPlaceholdersSoWineFindsWinemetal() throws {
        // Wine loads a DLL that isn't one of its own only through a placeholder on the search path; DXMT's d3d11/dxgi
        // import winemetal.dll, and Wine's setup makes no placeholder for it.
        let runtime = Runtime(url: dir.appendingPathComponent("runtime"))
        write("runtime/lib/dxmt/x86_64-windows/winemetal.dll", "x64")
        write("runtime/lib/dxmt/i386-windows/winemetal.dll", "x86")
        let bottle = Bottle(url: dir.appendingPathComponent("bottle"))
        try fm.createDirectory(at: bottle.cDrive.appendingPathComponent("windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bottle.cDrive.appendingPathComponent("windows/syswow64"), withIntermediateDirectories: true)
        BottleSetup.placeDXMTPlaceholders(bottle, runtime: runtime)
        XCTAssertEqual(try String(contentsOf: bottle.cDrive.appendingPathComponent("windows/system32/winemetal.dll"), encoding: .utf8), "x64")
        XCTAssertEqual(try String(contentsOf: bottle.cDrive.appendingPathComponent("windows/syswow64/winemetal.dll"), encoding: .utf8), "x86")
        // a bottle that has one already (CrossOver's) keeps it
        write("bottle/drive_c/windows/system32/winemetal.dll", "crossover")
        BottleSetup.placeDXMTPlaceholders(bottle, runtime: runtime)
        XCTAssertEqual(try String(contentsOf: bottle.cDrive.appendingPathComponent("windows/system32/winemetal.dll"), encoding: .utf8), "crossover")
    }

    func testPersonalFoldersInside() throws {
        let home = dir.appendingPathComponent("home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        write("home/Documents/save.dat", "progress")
        let profile = dir.appendingPathComponent("bottle/drive_c/users/crossover")
        try fm.createDirectory(at: profile.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: profile.appendingPathComponent("Documents"), withDestinationURL: home)

        try BottleSetup.keepPersonalFoldersInside(Bottle(url: dir.appendingPathComponent("bottle")))

        for name in BottleSetup.personal {
            let folder = profile.appendingPathComponent(name)
            XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: folder.path), name)
            XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(".stepover-keep").path), name)
        }
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("save.dat").path))
    }
}
