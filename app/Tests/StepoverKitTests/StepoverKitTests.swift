@testable import StepoverKit
import XCTest

final class StepoverKitTests: XCTestCase {
    func testCompatConfPerProgramAndProcessRules() {
        var config = BottleConfig(graphics: .d3dmetal)
        config.programs = [
            Program(name: "L.A. Noire", exe: #"C:\Program Files\LA Noire\LANoire.exe"#, graphics: .dxmt),
            Program(name: "RDR2", exe: #"C:\Games\RDR2.exe"#, env: ["D3DM_ENABLE_METALFX": "1"]),
        ]
        config.processes = ["Duckov.exe": ProcessRule(graphics: .wined3d)]
        let conf = config.compatConf()
        XCTAssertTrue(conf.contains("[*]\nbackend = d3dmetal\n"))
        XCTAssertTrue(conf.contains("[lanoire.exe]\nbackend = dxmt\n"))
        XCTAssertTrue(conf.contains("[rdr2.exe]\nbackend = d3dmetal\nenv = D3DM_ENABLE_METALFX=1\n"))
        XCTAssertTrue(conf.contains("[duckov.exe]\nbackend = wined3d\n"))
    }

    func testCompatConfProcessArgs() throws {
        var config = BottleConfig(graphics: .d3dmetal)
        config.processes = ["steamwebhelper.exe": ProcessRule(args: ["--in-process-gpu"])]
        XCTAssertTrue(config.compatConf().contains("[steamwebhelper.exe]\nbackend = d3dmetal\nargs = --in-process-gpu\n"))
        let json = #"{"processes": {"steamwebhelper.exe": {"args": ["--in-process-gpu"]}}}"#
        let decoded = try JSONDecoder().decode(BottleConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.processes["steamwebhelper.exe"]?.args, ["--in-process-gpu"])
    }

    func testRuntimeIsCurrentOnlyWhenItRecordsTheSameDownload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stepover-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = Runtime(url: dir.appendingPathComponent("cx26.3"))
        try FileManager.default.createDirectory(at: runtime.url, withIntermediateDirectories: true)
        let manifest = RuntimeManifest(name: "cx26.3", url: "https://example.invalid/rt.tar.xz", sha256: "AAA", size: 1, summary: nil)
        XCTAssertFalse(manifest.matches(runtime))  // installed before records existed (0.1.1)
        try RuntimeInstaller.record(manifest, in: runtime)
        XCTAssertTrue(manifest.matches(runtime))
        var newer = manifest
        newer.sha256 = "bbb"
        XCTAssertFalse(newer.matches(runtime))
    }

    func testBuiltInFixesApplyInEveryBottleWithoutRepeats() {
        let plain = BottleConfig(graphics: .dxmt).compatConf()
        XCTAssertTrue(plain.contains("[steamwebhelper.exe]\nbackend = dxmt\nargs = --in-process-gpu\n"))
        var config = BottleConfig(graphics: .d3dmetal)
        config.processes = ["SteamWebHelper.exe": ProcessRule(graphics: .wined3d, args: ["--in-process-gpu"])]
        let conf = config.compatConf()
        XCTAssertTrue(conf.contains("[steamwebhelper.exe]\nbackend = wined3d\nargs = --in-process-gpu\n"))
        XCTAssertEqual(conf.components(separatedBy: "args = --in-process-gpu").count, 2)
    }

    func testBottleCanTurnOffBuiltInFixesAndArgsStayOneLine() throws {
        var config = try JSONDecoder().decode(BottleConfig.self, from: Data(#"{"builtInFixes": false}"#.utf8))
        XCTAssertFalse(config.builtInFixes)
        XCTAssertFalse(config.compatConf().contains("steamwebhelper.exe"))
        config.processes = ["game.exe": ProcessRule(args: ["-windowed", "-a\n[*]\nbackend = dxvk"])]
        let conf = config.compatConf()
        XCTAssertTrue(conf.contains("[game.exe]\nbackend = d3dmetal\nargs = -windowed\n"))
        XCTAssertFalse(conf.contains("backend = dxvk"))
        XCTAssertTrue(BottleConfig().builtInFixes)
    }

    func testMSyncIsOffUnlessSetToOne() {
        var config = BottleConfig()
        XCTAssertFalse(config.msync)
        config.env["WINEMSYNC"] = "1"
        XCTAssertTrue(config.msync)
        config.msync = false
        XCTAssertEqual(config.env["WINEMSYNC"], "0")
    }

    func testCrossOverEnvironmentSection() {
        let conf = """
        [Bottle]
        "Version" = "26.3.0.39832"
        [EnvironmentVariables]
        ;; comment
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        "WINEESYNC" = "1"
        "D3DM_ENABLE_METALFX" = "1"
        [Other]
        "NOT_ENV" = "x"
        """
        XCTAssertEqual(Importer.crossOverEnvironment(conf),
                       ["CX_GRAPHICS_BACKEND": "d3dmetal", "WINEESYNC": "1", "D3DM_ENABLE_METALFX": "1"])
    }

    func testRegistryFileReadsStringsDwordsAndContinuations() throws {
        let reg = """
        WINE REGISTRY Version 2

        [Software\\\\Wine\\\\Mac Driver] 1792650177
        #time=1db45c1a3c8c9d0
        "RetinaMode"="y"

        [Control Panel\\\\Desktop] 1792650177
        "LogPixels"=dword:000000c0
        "UserPreferencesMask"=hex:9e,1e,07,80,12,\\
          00,00,00
        "Quoted \\"name\\""="a\\\\b"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stepover-test-\(UUID().uuidString).reg")
        try reg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = RegistryFile(url: url)
        XCTAssertEqual(file.string(#"Software\Wine\Mac Driver"#, "RetinaMode"), "y")
        XCTAssertEqual(file.dword(#"control panel\desktop"#, "LogPixels"), 192)
        XCTAssertEqual(file.raw(#"Control Panel\Desktop"#, "UserPreferencesMask"), "hex:9e,1e,07,80,12,00,00,00")
        XCTAssertEqual(file.string(#"Control Panel\Desktop"#, "Quoted \"name\""), #"a\b"#)
    }

    func testRegistryPatchText() {
        var patch = RegistryPatch()
        patch.set(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", .string("y"))
        patch.set(#"HKEY_CURRENT_USER\Control Panel\Desktop"#, "LogPixels", .dword(96))
        XCTAssertEqual(patch.text, "REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n\"RetinaMode\"=\"y\"\r\n\r\n[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n\"LogPixels\"=dword:00000060\r\n\r\n")
    }

    func testWindowsPathRoundTrip() throws {
        let fm = FileManager.default
        let bottle = fm.temporaryDirectory.appendingPathComponent("stepover-test-bottle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: bottle) }
        try fm.createDirectory(at: bottle.appendingPathComponent("drive_c/Games/My Game"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bottle.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bottle.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: bottle.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        let mac = try XCTUnwrap(WindowsPath.toMac(#"C:\Games\My Game\game.exe"#, bottle: bottle))
        XCTAssertEqual(mac.path, bottle.appendingPathComponent("drive_c/Games/My Game/game.exe").resolvingSymlinksInPath().path)
        try Data().write(to: mac)
        XCTAssertEqual(WindowsPath.toWindows(mac, bottle: bottle), #"C:\Games\My Game\game.exe"#)
        XCTAssertEqual(WindowsPath.toWindows(URL(fileURLWithPath: "/usr/bin/true"), bottle: bottle), #"Z:\usr\bin\true"#)
        XCTAssertEqual(WindowsPath.fileName(#"C:\a\RDR2.exe"#), "RDR2.exe")
    }
}
