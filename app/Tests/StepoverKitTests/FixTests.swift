@testable import StepoverKit
import XCTest

final class FixTests: XCTestCase {
    func decode(_ json: String) throws -> [Fix] { try Fix.decodeFile(Data(json.utf8)) }

    func testFullFixDecodesAndIsClean() throws {
        let fix = try XCTUnwrap(decode("""
        {"name": "Stumble Guys", "match": {"steam": [1677740], "exe": ["Stumble Guys.exe"]},
         "graphics": "d3dmetal", "env": {"A": "1"}, "args": ["-windowed"], "dlls": {"ddraw": "native,builtin"},
         "components": ["vcrun2022"], "notes": "n", "source": "s",
         "registry": [{"key": "HKCU\\\\Software\\\\Wine\\\\Direct3D", "name": "csmt", "type": "REG_DWORD", "value": "0"}]}
        """).first)
        XCTAssertEqual(fix.match.steam, [1677740])
        XCTAssertEqual(fix.dlls["ddraw"], "native,builtin")
        XCTAssertEqual(fix.problems(), [])
        XCTAssertEqual(fix.flagged(), [])
    }

    func testFileMayHoldAnArrayAndOnlyNameAndMatchAreRequired() throws {
        let fixes = try decode(#"[{"name": "A", "match": {"exe": ["a.exe"]}}, {"name": "B", "match": {"steam": [1]}}]"#)
        XCTAssertEqual(fixes.map(\.name), ["A", "B"])
        XCTAssertTrue(fixes.allSatisfy { $0.problems().isEmpty })
    }

    func testInvalidDataIsReported() throws {
        let fix = try XCTUnwrap(decode("""
        {"name": "", "match": {}, "graphics": "opengl", "dlls": {"d3d9": "sometimes"}, "components": ["Bad Verb"],
         "args": ["a\\nb"], "env": {"1BAD": "x"},
         "registry": [{"key": "HKCR\\\\x", "name": "n", "type": "REG_MULTI_SZ", "value": "v"}]}
        """).first)
        let problems = fix.problems().joined(separator: "\n")
        for word in ["name", "match", "opengl", "sometimes", "Bad Verb", "line break", "1BAD", "HKCR", "REG_MULTI_SZ"] {
            XCTAssertTrue(problems.contains(word), "expected a problem mentioning \(word): \(problems)")
        }
    }

    func testFlaggedItemsAreThoseOutsideVendorKeysAndCodeLoaders() throws {
        let fix = try XCTUnwrap(decode("""
        {"name": "X", "match": {"exe": ["x.exe"]},
         "env": {"DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "WINEPREFIX": "/", "SteamAppId": "1", "MY_SETTING": "1"},
         "dlls": {"steam_api64": "native", "dinput8": "native,builtin"},
         "registry": [
           {"key": "HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run", "name": "x", "type": "REG_SZ", "value": "cmd /c del"},
           {"key": "HKLM\\\\Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Image File Execution Options\\\\game.exe", "name": "Debugger", "type": "REG_SZ", "value": "cmd"},
           {"key": "HKCU\\\\Software\\\\Classes\\\\txtfile\\\\shell\\\\open\\\\command", "name": "", "type": "REG_SZ", "value": "cmd"},
           {"key": "HKCU\\\\Environment", "name": "PATH", "type": "REG_SZ", "value": "x"},
           {"key": "HKLM\\\\System\\\\CurrentControlSet\\\\Services\\\\evil", "name": "ImagePath", "type": "REG_SZ", "value": "cmd"},
           {"key": "HKCU\\\\Software\\\\Game Studio\\\\Game", "name": "LicenseKey", "type": "REG_SZ", "value": "ABC"},
           {"key": "HKCU\\\\Software\\\\Game Studio\\\\Game", "name": "Quality", "type": "REG_DWORD", "value": "3"},
           {"key": "HKCU\\\\Software\\\\Wine\\\\WineBrowser", "name": "Browsers", "type": "REG_SZ", "value": "/bin/sh -c x"},
           {"key": "HKCU\\\\Software\\\\Wine\\\\AppDefaults\\\\game.exe", "name": "Version", "type": "REG_SZ", "value": "win7"},
           {"key": "HKCU\\\\Software\\\\Wine\\\\Direct3D", "name": "csmt", "type": "REG_DWORD", "value": "0"},
           {"key": "HKLM\\\\Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Windows", "name": "AppInit_DLLs", "type": "REG_SZ", "value": "x.dll"},
           {"key": "HKLM\\\\Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\AeDebug", "name": "Debugger", "type": "REG_SZ", "value": "cmd"},
           {"key": "HKCU\\\\Control Panel\\\\Desktop", "name": "SCRNSAVE.EXE", "type": "REG_SZ", "value": "x"}
         ]}
        """).first)
        XCTAssertEqual(fix.problems(), [])
        let flagged = fix.flagged().joined(separator: "\n")
        for word in ["DYLD_INSERT_LIBRARIES", "WINEPREFIX", "\\Run", "Image File Execution Options", "shell\\open\\command",
                     "Environment", "Services", "AppInit_DLLs", "AeDebug", "Control Panel", "WineBrowser", "LicenseKey"] {
            XCTAssertTrue(flagged.contains(word), "expected \(word) flagged: \(flagged)")
        }
        for word in ["steam_api64", "dinput8", "SteamAppId", "MY_SETTING", "Quality", "csmt", "AppDefaults"] {
            XCTAssertFalse(flagged.contains(word), "\(word) should not be flagged")
        }
        let safe = fix.withoutFlagged()
        XCTAssertEqual(safe.flagged(), [])
        XCTAssertEqual(Set(safe.env.keys), ["SteamAppId", "MY_SETTING"])
        XCTAssertEqual(safe.registry.map(\.name).sorted(), ["Quality", "Version", "csmt"])
        XCTAssertEqual(safe.dlls.count, 2)
    }

    func testMatchingBySteamInstallAndExeName() throws {
        let game = FileManager.default.temporaryDirectory.appendingPathComponent("stepover-game-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: game) }
        for path in ["Game.exe", "UnityCrashHandler64.exe", "Bin/Engine.exe", "_CommonRedist/vc_redist.x64.exe"] {
            let url = game.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let steam = SteamApp(id: 42, name: "Game", folder: game, windowsFolder: #"C:\Steam\common\Game"#)
        var bySteam = Fix(name: "Game", match: .init(steam: [42]))
        bySteam.id = "official/games/game.json"
        bySteam.args = ["-dx11"]
        var notInstalled = Fix(name: "Other", match: .init(steam: [7]))
        notInstalled.id = "official/games/other.json"
        var byExe = Fix(name: "Tool", match: .init(exe: ["Tool.exe"]))
        byExe.id = "local/tool.json"

        var config = BottleConfig()
        // a fix applies only where its game is found: a Steam install, or a program file in the bottle
        var matched = config.matchedFixes([bySteam, notInstalled, byExe], programs: [], steamApps: [steam])
        XCTAssertEqual(matched.map(\.fix.name), ["Game"])
        XCTAssertEqual(matched[0].programs, [#"c:\steam\common\game\bin\engine.exe"#, #"c:\steam\common\game\game.exe"#])
        XCTAssertEqual(matched[0].argPrograms, [#"c:\steam\common\game\game.exe"#])
        matched = config.matchedFixes([bySteam, byExe], programs: ["tool.exe"], steamApps: [steam])
        XCTAssertEqual(matched.map(\.fix.name), ["Game", "Tool"])

        config.disabledFixes = ["official/games/game.json"]
        matched = config.matchedFixes([bySteam, byExe], programs: ["tool.exe"], steamApps: [steam])
        XCTAssertEqual(matched.map(\.fix.name), ["Tool"])
        config.fixes = false
        XCTAssertTrue(config.matchedFixes([bySteam, byExe], programs: ["tool.exe"], steamApps: [steam]).isEmpty)
    }

    func testProgramFilesNextToABottleProgramCount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stepover-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in ["DuckovLauncher.exe", "Duckov.exe", "Data/Tools/Helper.exe", "UnityCrashHandler64.exe"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let names = Launcher.programFiles(near: [folder.appendingPathComponent("DuckovLauncher.exe")])
        XCTAssertEqual(names, ["duckov.exe", "duckovlauncher.exe", "helper.exe"])
    }

    func testOneFixPerGameTheLastLoadedWins() {
        var converted = Fix(name: "RDR2 (converted)", match: .init(steam: [1174180]))
        converted.id = "official/proton/steam-1174180.json"
        converted.args = ["-vulkan"]
        var written = Fix(name: "RDR2", match: .init(steam: [1174180], exe: ["RDR2.exe"]))
        written.id = "official/games/rdr2.json"
        let app = SteamApp(id: 1174180, name: "RDR2", folder: URL(fileURLWithPath: "/nonexistent"), windowsFolder: "C:\\x")
        var config = BottleConfig()
        XCTAssertEqual(config.matchedFixes([converted, written], programs: ["rdr2.exe"], steamApps: [app]).map(\.fix.name), ["RDR2"])
        config.disabledFixes = [written.id]  // turning the winner off doesn't bring the converted one back
        XCTAssertTrue(config.matchedFixes([converted, written], programs: ["rdr2.exe"], steamApps: [app]).isEmpty)
    }

    func testTheBottlesOwnEnvironmentAndDllOverridesWin() {
        var fix = Fix(name: "Game", match: .init(exe: ["Game.exe"]))
        fix.env = ["A": "1", "B": "2"]
        fix.dlls = ["ddraw": "native", "dinput8": "native"]
        let matched = MatchedFix(fix: fix, programs: ["game.exe"], argPrograms: [])
        var config = BottleConfig(graphics: .d3dmetal)
        config.env = ["A": "0", "WINEDLLOVERRIDES": "ddraw.dll=b;x=n"]
        let conf = config.compatConf(fixes: [matched])
        XCTAssertTrue(conf.contains("[game.exe]\nbackend = d3dmetal\nenv = B=2\ndll = dinput8=n\n"), conf)
    }

    func testUserRulesWinOverFullPathFixSectionsWhateverTheOrder() {
        var fix = Fix(name: "Z", match: .init(steam: [5]))
        fix.graphics = "dxmt"
        fix.env = ["A": "fix", "B": "fix"]
        fix.dlls = ["ddraw": "native"]
        let path = #"c:\steam\common\z\zgame.exe"#
        let matched = MatchedFix(fix: fix, programs: [path], argPrograms: [path])
        var config = BottleConfig(graphics: .d3dmetal)
        config.processes = ["ZGame.exe": ProcessRule(graphics: .wined3d, env: ["A": "mine", "WINEDLLOVERRIDES": "ddraw=b"])]
        let conf = config.compatConf(fixes: [matched])
        let pathSection = conf.components(separatedBy: "[\(path)]\n").last ?? ""
        XCTAssertTrue(pathSection.hasPrefix("backend = wined3d\nenv = A=mine\nenv = B=fix\nenv = WINEDLLOVERRIDES=ddraw=b\n"), pathSection)
        XCTAssertTrue(pathSection.contains("dll = ddraw=b\n"), pathSection)   // the user's own override, not the fix's
        XCTAssertFalse(pathSection.contains("dll = ddraw=n"))
        // full-path sections come after every file-name section
        XCTAssertLessThan(conf.range(of: "[zgame.exe]")!.lowerBound, conf.range(of: "[\(path)]")!.lowerBound)
        XCTAssertEqual("ÄBC.EXE".asciiLowercased, "Äbc.exe")
    }

    func testUnsafeSectionNamesAreNotWritten() {
        var config = BottleConfig()
        config.processes = ["evil]\n[*]\nenv = X=1\n[a.exe": ProcessRule(graphics: .dxmt)]
        XCTAssertFalse(config.compatConf().contains("evil"))
    }

    func testMatchedFixesGoIntoTheCompatFileBeneathBottleRules() throws {
        var fix = Fix(name: "Game", match: .init(exe: ["Game.exe"]))
        fix.graphics = "dxmt"
        fix.env = ["A": "1"]
        fix.dlls = ["ddraw": "native,builtin"]
        fix.args = ["-dx11"]
        let matched = MatchedFix(fix: fix, programs: ["game.exe"], argPrograms: ["game.exe"])
        var config = BottleConfig(graphics: .d3dmetal)
        XCTAssertTrue(config.compatConf(fixes: [matched])
            .contains("[game.exe]\nbackend = dxmt\nenv = A=1\ndll = ddraw=n,b\nargs = -dx11\n"))
        config.processes = ["game.exe": ProcessRule(graphics: .wined3d, env: ["A": "2"])]
        XCTAssertTrue(config.compatConf(fixes: [matched])
            .contains("[game.exe]\nbackend = wined3d\nenv = A=2\ndll = ddraw=n,b\nargs = -dx11\n"))
    }

    func testProgramNamesCannotInjectIntoTheCompatFile() throws {
        let fix = try XCTUnwrap(decode(#"{"name": "X", "match": {"steam": [1], "exe": ["x]\n[*]\nenv = HOME=..\n[y.exe", "a=b.exe", "ok.exe"]}}"#).first)
        let problems = fix.problems().joined(separator: "\n")
        XCTAssertTrue(problems.contains("a=b.exe"))
        XCTAssertEqual(fix.problems().count, 2)
        XCTAssertTrue(Fix.isProgramName("Stumble Guys.exe"))
    }

    func testWholeBottleComponentsAreRefusedAndWindowsVersionIsPerProgram() throws {
        let fix = try XCTUnwrap(decode(#"{"name": "X", "match": {"steam": [1]}, "components": ["d3dx9", "winxp", "sound=alsa", "ole32"], "windowsVersion": "win12"}"#).first)
        let problems = fix.problems().joined(separator: "\n")
        for word in ["winxp", "windowsVersion", "sound=alsa", "ole32", "win12"] { XCTAssertTrue(problems.contains(word), word) }
        XCTAssertFalse(problems.contains("d3dx9"))
        XCTAssertEqual(try decode(#"{"name": "Y", "match": {"steam": [1]}, "windowsVersion": "win7"}"#).first?.problems(), [])
    }

    func testFixesNamingSharedProgramsAreFlagged() throws {
        let fix = try XCTUnwrap(decode(#"{"name": "X", "match": {"exe": ["steam.exe", "Game.exe"]}}"#).first)
        XCTAssertEqual(fix.flagged().count, 1)
        XCTAssertEqual(fix.withoutFlagged().match.exe, ["Game.exe"])
    }

    func testDllOrderBecomesWineSyntax() {
        XCTAssertEqual(Fix.wineOverride("ddraw", "native,builtin"), "ddraw=n,b")
        XCTAssertEqual(Fix.wineOverride("dcomp", "disabled"), "dcomp=")
        XCTAssertEqual(Fix.wineOverride("x", "builtin"), "x=b")
    }

    func testCompatConfStartsWithVersion() {
        XCTAssertTrue(BottleConfig().compatConf().hasPrefix(
            "# Written by Stepover from stepover.json; edit that file (or use the app) instead.\n\nversion = 3\n\n[*]\n"))
    }

    func testNeededCompatFormat() {
        var withDlls = Fix(name: "A", match: .init(exe: ["a.exe"]))
        withDlls.dlls = ["d3d9": "native"]
        XCTAssertEqual(MatchedFix(fix: withDlls, programs: ["a.exe"], argPrograms: []).neededCompatFormat, 3)
        let bySteamPath = Fix(name: "B", match: .init(steam: [1]))
        XCTAssertEqual(MatchedFix(fix: bySteamPath, programs: [#"c:\program files (x86)\steam\steamapps\common\b\b.exe"#],
                                  argPrograms: []).neededCompatFormat, 3)
        var withArgs = Fix(name: "C", match: .init(exe: ["c.exe"]))
        withArgs.args = ["-dx12"]
        XCTAssertEqual(MatchedFix(fix: withArgs, programs: ["c.exe"], argPrograms: ["c.exe"]).neededCompatFormat, 2)
        var envOnly = Fix(name: "D", match: .init(exe: ["d.exe"]))
        envOnly.env = ["X": "1"]
        envOnly.graphics = "dxmt"
        XCTAssertEqual(MatchedFix(fix: envOnly, programs: ["d.exe"], argPrograms: []).neededCompatFormat, 1)
    }
}
