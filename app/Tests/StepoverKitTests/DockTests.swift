import XCTest
@testable import StepoverKit

final class DockTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).json")
    }

    func testRecentGamesNewestFirstWithoutDuplicates() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        RecentGames.record("Hi-Fi RUSH", bottle: "Hi-Fi Rush", at: Date(timeIntervalSince1970: 1), in: file)
        RecentGames.record("Steam", bottle: "Steam", at: Date(timeIntervalSince1970: 2), in: file)
        RecentGames.record("Hi-Fi RUSH", bottle: "Hi-Fi Rush", at: Date(timeIntervalSince1970: 3), in: file)
        XCTAssertEqual(RecentGames.load(from: file).map(\.program), ["Hi-Fi RUSH", "Steam"])
    }

    func testRecentGamesKeepsTheSameNameInOtherBottles() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        RecentGames.record("Game", bottle: "A", at: Date(timeIntervalSince1970: 1), in: file)
        RecentGames.record("Game", bottle: "B", at: Date(timeIntervalSince1970: 2), in: file)
        XCTAssertEqual(RecentGames.load(from: file).map(\.bottle), ["B", "A"])
    }

    func testRecentGamesIsCapped() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        for i in 0..<(RecentGames.limit + 5) {
            RecentGames.record("Game \(i)", bottle: "A", at: Date(timeIntervalSince1970: Double(i)), in: file)
        }
        let entries = RecentGames.load(from: file)
        XCTAssertEqual(entries.count, RecentGames.limit)
        XCTAssertEqual(entries.first?.program, "Game \(RecentGames.limit + 4)")
    }

    func testMissingRecentFileIsEmpty() {
        XCTAssertEqual(RecentGames.load(from: tempFile()), [])
    }

    func testProcessesMatchOnlyTheirBottle() {
        let processes = [
            RunningPrograms.Process(pid: 1, windowsPath: "C:\\Games\\RDR2\\RDR2.exe", cwd: "/b/RDR2/drive_c/Games/RDR2"),
            RunningPrograms.Process(pid: 2, windowsPath: "C:\\windows\\system32\\explorer.exe", cwd: "/b/RDR2/drive_c/windows/system32"),
            RunningPrograms.Process(pid: 3, windowsPath: "C:\\Mods\\Launcher.exe", cwd: "/b/RDR2 Mods/drive_c/Mods"),
        ]
        XCTAssertEqual(RunningPrograms.inBottle(processes, bottlePath: "/b/RDR2").map(\.pid), [1, 2])
        XCTAssertEqual(RunningPrograms.inBottle(processes, bottlePath: "/b/RDR2 Mods").map(\.pid), [3])
    }

    func testProcessNames() {
        let game = RunningPrograms.Process(pid: 1, windowsPath: "C:\\Games\\RDR2\\RDR2.exe", cwd: "/")
        let wine = RunningPrograms.Process(pid: 2, windowsPath: "C:\\windows\\system32\\explorer.exe", cwd: "/")
        XCTAssertEqual(game.exeName, "rdr2.exe")
        XCTAssertFalse(game.isSystem)
        XCTAssertTrue(wine.isSystem)
        XCTAssertTrue(RunningPrograms.isWindowsPath("C:\\windows\\system32\\notepad.exe"))
        XCTAssertTrue(RunningPrograms.isWindowsPath("d:\\setup.exe"))
        XCTAssertFalse(RunningPrograms.isWindowsPath("/usr/bin/zsh"))
        XCTAssertFalse(RunningPrograms.isWindowsPath("C:"))
    }

    func testListingLiveProcessesDoesNotCrash() {
        XCTAssertTrue(RunningPrograms.processes().allSatisfy { RunningPrograms.isWindowsPath($0.windowsPath) })
    }
}
