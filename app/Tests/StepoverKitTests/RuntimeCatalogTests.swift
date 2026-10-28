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

    /// Holds the bottle's wineserver lock from another process, as a running wineserver does
    /// (a process never sees its own lock with F_GETLK). Terminate the returned process to release it.
    private func holdServerLock(_ bottle: Bottle) throws -> Process {
        let lock = try XCTUnwrap(bottle.serverLockPath)
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
        _ = out.fileHandleForReading.availableData   // waits for "locked"
        return holder
    }

    private func release(_ holder: Process, _ bottle: Bottle) {
        holder.terminate(); holder.waitUntilExit()
        if let lock = bottle.serverLockPath { try? FileManager.default.removeItem(atPath: (lock as NSString).deletingLastPathComponent) }
    }

    func testRemoveRefusesWhileRunning() throws {
        let runtime = try fakeRuntime("cx26.3")
        let bottleURL = dir.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        let bottle = Bottle(url: bottleURL)
        let holder = try holdServerLock(bottle)
        defer { release(holder, bottle) }
        XCTAssertTrue(bottle.isRunning)

        XCTAssertThrowsError(try RuntimeCatalog.remove(runtime, bottles: [bottle], resolved: { _ in "cx26.3" })) { error in
            XCTAssertEqual(error.localizedDescription, "Game is running on cx26.3; quit it first")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.url.path))
    }

    /// The pin changed while the game runs: Wine is still on the runtime it started with (lastRuntime).
    func testRemoveRefusesWhileRunningOnLastRuntimeAfterPinChange() throws {
        let runtime = try fakeRuntime("cx26.3")
        let bottleURL = dir.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        let bottle = Bottle(url: bottleURL)
        bottle.lastRuntime = "cx26.3"
        let holder = try holdServerLock(bottle)
        defer { release(holder, bottle) }

        XCTAssertThrowsError(try RuntimeCatalog.remove(runtime, bottles: [bottle], resolved: { _ in "cx26.5" })) { error in
            XCTAssertEqual(error.localizedDescription, "Game is running on cx26.3; quit it first")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.url.path))
    }

    func testRunningBottleCountsAsUserOfItsLastRuntime() {
        XCTAssertEqual(RuntimeCatalog.inUse(resolved: "cx26.5", running: true, lastRuntime: "cx26.3"), "cx26.3")
        XCTAssertEqual(RuntimeCatalog.inUse(resolved: "cx26.5", running: false, lastRuntime: "cx26.3"), "cx26.5")
        XCTAssertEqual(RuntimeCatalog.inUse(resolved: "cx26.5", running: true, lastRuntime: nil), "cx26.5")
    }

    func testRemoveDeletesIdleRuntime() throws {
        let runtime = try fakeRuntime("cx26.3")
        let bottleURL = dir.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        try RuntimeCatalog.remove(runtime, bottles: [Bottle(url: bottleURL)], resolved: { _ in "cx26.3" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.url.path))
    }

    private func index(pulled: String? = nil, note: String? = nil) -> RuntimeIndex {
        RuntimeIndex(runtimes: ["cx26.3", "cx26.4"].map { name in
            var m = RuntimeManifest(name: name, url: "https://example.com/\(name).tar.xz", sha256: String(repeating: "a", count: 64), size: 1, summary: nil)
            if name == pulled { m.status = .pulled; m.note = note }
            return m
        })
    }

    func testStateNewest() {
        XCTAssertEqual(RuntimeCatalog.state(pinned: nil, resolved: "cx26.4", installed: ["cx26.3", "cx26.4"], index: index()), .newest("cx26.4"))
    }

    func testStatePinnedBehind() {
        XCTAssertEqual(RuntimeCatalog.state(pinned: "cx26.3", resolved: "cx26.3", installed: ["cx26.3", "cx26.4"], index: index()),
                       .pinned("cx26.3", newer: "cx26.4"))
    }

    func testStatePinnedLatest() {
        XCTAssertEqual(RuntimeCatalog.state(pinned: "cx26.4", resolved: "cx26.4", installed: ["cx26.3", "cx26.4"], index: index()),
                       .pinned("cx26.4", newer: nil))
    }

    func testStateMissingPin() {
        XCTAssertEqual(RuntimeCatalog.state(pinned: "cx26.2", resolved: "cx26.4", installed: ["cx26.3", "cx26.4"], index: index()),
                       .missingPin("cx26.2", using: "cx26.4"))
    }

    func testStateOnPulled() {
        XCTAssertEqual(RuntimeCatalog.state(pinned: nil, resolved: "cx26.4", installed: ["cx26.3", "cx26.4"],
                                            index: index(pulled: "cx26.4", note: "breaks RDR2")),
                       .onPulled("cx26.4", note: "breaks RDR2", suggested: "cx26.3"))
    }
}
