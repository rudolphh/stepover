import XCTest
@testable import StepoverKit

final class CouchTests: XCTestCase {
    func testRowClampsAndRepeats() {
        var row = CouchRow(count: 4)
        row.move(-1); XCTAssertEqual(row.index, 0)
        row.move(10); XCTAssertEqual(row.index, 3)
        row.move(-1); XCTAssertEqual(row.index, 2)
        XCTAssertEqual(CouchRow(count: 0).index, 0)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.1), 1)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.4), 1)
        XCTAssertEqual(CouchRow.repeats(heldFor: 0.64), 3)     // 1 + repeats at 0.52 and 0.64
    }

    func testShortcutFiresOncePerHold() {
        var d = ShortcutDetector()
        XCTAssertFalse(d.update([.select, .menu], at: 0))      // menu is Start
        XCTAssertFalse(d.update([.select, .menu], at: 0.9))
        XCTAssertTrue(d.update([.select, .menu], at: 1.0))
        XCTAssertFalse(d.update([.select, .menu], at: 1.5))    // still held: no second time
        XCTAssertFalse(d.update([], at: 1.6))
        XCTAssertFalse(d.update([.home], at: 2.0))
        XCTAssertTrue(d.update([.home], at: 2.5))
        XCTAssertFalse(d.update([.home], at: 2.3))             // time going backwards never fires again
    }

    func testShortReleaseNeverFires() {
        var d = ShortcutDetector()
        XCTAssertFalse(d.update([.select, .menu], at: 0))
        XCTAssertFalse(d.update([], at: 0.9))
        XCTAssertFalse(d.update([.select, .menu], at: 1.2))    // a fresh hold starts at 1.2
        XCTAssertFalse(d.update([.select, .menu, .a], at: 2.1))
        XCTAssertTrue(d.update([.select, .menu], at: 2.2))
        XCTAssertFalse(d.update([.select], at: 5))             // one button alone is never the chord
    }

    func testPrimaryAction() {
        XCTAssertEqual(Couch.primary(selected: "a", running: nil), .play)
        XCTAssertEqual(Couch.primary(selected: "a", running: "a"), .resume)
        XCTAssertEqual(Couch.primary(selected: "a", running: "b"), .quitAndPlay(running: "b"))
    }
}
