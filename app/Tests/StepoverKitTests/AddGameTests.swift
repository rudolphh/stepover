import XCTest
@testable import StepoverKit

final class AddGameTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUp() {
        dir = fm.temporaryDirectory.appendingPathComponent("addgame-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: dir) }

    func testSafeNames() {
        XCTAssertEqual(AddGame.bottleName(for: "Batman: Arkham Asylum", in: dir), "Batman - Arkham Asylum")
        XCTAssertEqual(AddGame.installDir(for: "What?/Why*"), #"C:\Games\What - Why"#)
        XCTAssertEqual(AddGame.installDir(for: "Assassin's Creed & Pokémon"), #"C:\Games\Assassin's Creed & Pokémon"#)
        XCTAssertEqual(AddGame.bottleName(for: "...", in: dir), "Game")
    }

    func testBottleNameTakenGetsANumber() throws {
        try fm.createDirectory(at: dir.appendingPathComponent("Tiny Game"), withIntermediateDirectories: true)
        XCTAssertEqual(AddGame.bottleName(for: "Tiny Game", in: dir), "Tiny Game 2")
        try fm.createDirectory(at: dir.appendingPathComponent("Tiny Game 2"), withIntermediateDirectories: true)
        XCTAssertEqual(AddGame.bottleName(for: "Tiny Game", in: dir), "Tiny Game 3")
    }

    func testSilentArguments() {
        // Arguments are passed one by one; Wine quotes one with spaces as a whole, which Inno reads (Task 1, F1/F2).
        XCTAssertEqual(AddGame.silentArguments(.inno, dir: #"C:\Games\A B"#, log: #"C:\l.log"#),
                       ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", #"/DIR=C:\Games\A B"#, #"/LOG=C:\l.log"#])
        XCTAssertEqual(AddGame.silentArguments(.nsis, dir: #"C:\Games\A B"#, log: "x"), ["/S", #"/D=C:\Games\A B"#])
        XCTAssertEqual(AddGame.silentArguments(.msi, dir: #"C:\Games\A B"#, log: "x"),
                       ["/qn", #"TARGETDIR=C:\Games\A B"#, #"INSTALLDIR=C:\Games\A B"#])
        XCTAssertEqual(AddGame.silentArguments(.other, dir: #"C:\Games\A B"#, log: "x"), [])
    }

    func testDiscardOnlyItsOwnBottle() throws {
        let bottle = dir.appendingPathComponent("Tiny Game")
        try fm.createDirectory(at: bottle, withIntermediateDirectories: true)
        try InstallOutcome(job: "j1").save(to: Bottle(url: bottle))
        XCTAssertThrowsError(try AddGame.discard(bottleNamed: "Tiny Game", job: "j2", in: dir))
        XCTAssertTrue(fm.fileExists(atPath: bottle.path))
        let other = dir.appendingPathComponent("Someone Else's")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AddGame.discard(bottleNamed: "Someone Else's", job: "j1", in: dir))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        try AddGame.discard(bottleNamed: "Tiny Game", job: "j1", in: dir)
        XCTAssertFalse(fm.fileExists(atPath: bottle.path))
    }

    func testLogTailRedacted() {
        let lines = ["2026-10-29 stepover: installing /Users/x/Downloads/Tiny/setup.exe",
                     #"start.exe /exec Z:\Users\x\Downloads\Tiny\setup.exe /VERYSILENT"#,
                     "log at /Users/x/Library/Logs/Stepover", #"Z:\Users\x\Documents"#]
        XCTAssertEqual(InstallOutcome.redact(lines, source: "/Users/x/Downloads/Tiny", home: "/Users/x"),
                       ["2026-10-29 stepover: installing <folder>/setup.exe", #"start.exe /exec <folder>\setup.exe /VERYSILENT"#,
                        "log at ~/Library/Logs/Stepover", #"~\Documents"#])
    }

    func testInstallProcessesIncludeTheInstallersFolder() {
        let bottle = Bottle(url: URL(fileURLWithPath: "/Users/x/Library/Application Support/Stepover/Bottles/Tiny Game"))
        let all = [RunningPrograms.Process(pid: 1, windowsPath: #"C:\Games\Tiny Game\_Redist\vc_redist.x64.exe"#, cwd: bottle.url.path + "/drive_c/Games"),
                   RunningPrograms.Process(pid: 2, windowsPath: #"C:\users\crossover\AppData\Local\Temp\is-A.tmp\setup.tmp"#, cwd: "/Users/x/Downloads/Tiny"),
                   RunningPrograms.Process(pid: 3, windowsPath: #"Z:\private\var\folders\ab\T\stepover-1\setup.exe"#, cwd: "/private/var/folders/ab/T/stepover-1"),
                   RunningPrograms.Process(pid: 4, windowsPath: #"C:\Games\Other\Other.exe"#, cwd: "/Users/x/Library/Application Support/Stepover/Bottles/Other/drive_c")]
        XCTAssertEqual(AddGame.installProcesses(all, bottle: bottle, installerFolder: URL(fileURLWithPath: "/Users/x/Downloads/Tiny")).map(\.pid), [1, 2])
        XCTAssertEqual(AddGame.installProcesses(all, bottle: bottle, installerFolder: URL(fileURLWithPath: "/var/folders/ab/T/stepover-1")).map(\.pid), [1, 3])
    }

    func testLargeAddressCopyGetsItsOwnLog() {
        let original = [#"C:\users\crossover\AppData\Local\Temp\is-A.tmp\setup.tmp"#, #"/SL5=$3004A,950272,0,Z:\x\setup.exe"#,
                        "/VERYSILENT", #"/DIR=C:\Games\Tiny Game"#, #"/LOG=C:\windows\temp\stepover-inno-1.log"#]
        XCTAssertEqual(AddGame.copyArguments(original, log: #"C:\windows\temp\stepover-inno-1-copy.log"#),
                       [#"/SL5=$3004A,950272,0,Z:\x\setup.exe"#, "/VERYSILENT", #"/DIR=C:\Games\Tiny Game"#,
                        #"/LOG=C:\windows\temp\stepover-inno-1-copy.log"#])
    }

    func testInnoErrorLine() {
        let log = """
        2026-10-29 12:55:03.300   Dest filename: C:\\Games\\Tiny Game\\TinyGame.exe
        2026-10-29 12:55:03.360   Defaulting to Abort for suppressed message box (Abort/Retry/Ignore):
                                  C:\\Games\\Tiny Game\\TinyGame.exe

                                  An error occurred while trying to copy a file:
                                  The source file is corrupted.
        2026-10-29 12:55:03.360   User canceled the installation process.
        """
        XCTAssertEqual(AddGame.innoError(fromLog: log), "The source file is corrupted.")
        XCTAssertNil(AddGame.innoError(fromLog: "2026-10-29 12:53:25.785   Installation process succeeded."))
    }
}
