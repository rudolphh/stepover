import XCTest
@testable import StepoverKit

final class RuntimeCatalogTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func fakeRuntime(_ name: String) throws -> Runtime {
        let bin = dir.appendingPathComponent("Runtimes/\(name)/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("wine"))
        return Runtime(url: bin.deletingLastPathComponent())
    }

    func testKeepsTwoNewestGood() {
        XCTAssertEqual(RuntimeCatalog.kept(installed: ["cx26.2", "cx26.3", "cx26.4", "cx26.5"], pulled: ["cx26.5"]),
                       ["cx26.3", "cx26.4"])
    }

    func testUsersArePinnedOrResolved() {
        let bottles: [(name: String, pinned: String?, resolved: String?)] =
            [("A", "cx26.3", "cx26.3"), ("B", nil, "cx26.4"), ("C", nil, "cx26.3")]
        XCTAssertEqual(RuntimeCatalog.users(of: "cx26.3", bottles: bottles), ["A", "C"])
    }

    func testRemoveRefusesWhileRunning() throws {
        let runtime = try fakeRuntime("cx26.3")
        let bottleURL = dir.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        let bottle = Bottle(url: bottleURL)
        let lock = try XCTUnwrap(bottle.serverLockPath)
        // Another process holds the lock, as a wineserver does (a process never sees its own lock with F_GETLK).
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-I", "-c", """
            import fcntl, os, sys, time
            os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
            f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX); print("locked", flush=True); time.sleep(60)
            """, lock]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer {
            holder.terminate(); holder.waitUntilExit()
            try? FileManager.default.removeItem(atPath: (lock as NSString).deletingLastPathComponent)
        }
        _ = out.fileHandleForReading.availableData   // waits for "locked"
        XCTAssertTrue(bottle.isRunning)

        XCTAssertThrowsError(try RuntimeCatalog.remove(runtime, bottles: [bottle], resolved: { _ in "cx26.3" })) { error in
            XCTAssertEqual(error.localizedDescription, "Game is running on cx26.3; quit it first")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.url.path))
    }

    func testRemoveDeletesIdleRuntime() throws {
        let runtime = try fakeRuntime("cx26.3")
        let bottleURL = dir.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        try RuntimeCatalog.remove(runtime, bottles: [Bottle(url: bottleURL)], resolved: { _ in "cx26.3" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.url.path))
    }
}
