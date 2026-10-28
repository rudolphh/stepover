import XCTest
@testable import StepoverKit

final class RuntimeChoiceTests: XCTestCase {
    private let both = ["cx26.3", "cx26.4"]

    func testPinnedWins() {
        XCTAssertEqual(Runtime.choose(pinned: "cx26.3", lastUsed: nil, installed: both, pulled: [], preferred: nil), "cx26.3")
    }

    func testMissingPinFallsBack() {
        XCTAssertEqual(Runtime.choose(pinned: "cx26.2", lastUsed: nil, installed: both, pulled: [], preferred: nil), "cx26.4")
    }

    func testPreferredBeatsNewest() {
        XCTAssertEqual(Runtime.choose(pinned: nil, lastUsed: nil, installed: both, pulled: [], preferred: "cx26.3"), "cx26.3")
    }

    func testNewestSkipsPulled() {
        XCTAssertEqual(Runtime.choose(pinned: nil, lastUsed: nil, installed: both, pulled: ["cx26.4"], preferred: nil), "cx26.3")
    }

    func testStaysOnPulledItAlreadyUses() {
        XCTAssertEqual(Runtime.choose(pinned: nil, lastUsed: "cx26.4", installed: both, pulled: ["cx26.4"], preferred: nil), "cx26.4")
    }

    func testAllPulledUsesNewest() {
        XCTAssertEqual(Runtime.choose(pinned: nil, lastUsed: nil, installed: both, pulled: ["cx26.3", "cx26.4"], preferred: nil), "cx26.4")
    }

    func testNothingInstalled() {
        XCTAssertNil(Runtime.choose(pinned: "cx26.3", lastUsed: "cx26.3", installed: [], pulled: [], preferred: nil))
    }

    func testLastRuntimeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bottle = Bottle(url: dir)
        XCTAssertNil(bottle.lastRuntime)
        bottle.lastRuntime = "cx26.4"
        XCTAssertEqual(Bottle(url: dir).lastRuntime, "cx26.4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".stepover-last-runtime").path))
    }
}
