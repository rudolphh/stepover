import XCTest
@testable import StepoverKit

final class GameArtTests: XCTestCase {
    private var dir: URL!, base: URL!, cache: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        base = dir.appendingPathComponent("cdn"); cache = dir.appendingPathComponent("Art")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func serve(_ id: Int, _ bytes: Data) throws {
        let folder = base.appendingPathComponent(String(id))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("library_600x900.jpg"))
    }

    func testRemoteURL() {
        XCTAssertEqual(GameArt.remoteURL(1174180).absoluteString,
                       "https://cdn.cloudflare.steamstatic.com/steam/apps/1174180/library_600x900.jpg")
    }

    func testFetchCachesAndRemembersMisses() async throws {
        try serve(1174180, Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        let art = await GameArt.fetch(1174180, into: cache, base: base.absoluteString)
        XCTAssertEqual(art?.lastPathComponent, "1174180.jpg")
        XCTAssertEqual(GameArt.cached(1174180, in: cache)?.lastPathComponent, "1174180.jpg")
        try FileManager.default.removeItem(at: base.appendingPathComponent("1174180"))   // offline now
        let again = await GameArt.fetch(1174180, into: cache, base: base.absoluteString)
        XCTAssertEqual(again?.lastPathComponent, "1174180.jpg")
        let missing = await GameArt.fetch(55230, into: cache, base: base.absoluteString)
        XCTAssertNil(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("55230.none").path))
        try serve(55230, Data([0xFF, 0xD8, 0xFF, 0xE0]))     // a remembered miss isn't asked again
        let remembered = await GameArt.fetch(55230, into: cache, base: base.absoluteString)
        XCTAssertNil(remembered)
    }

    func testNotAJPEGIsAMiss() async throws {
        try serve(7, Data("<html>404</html>".utf8))
        let art = await GameArt.fetch(7, into: cache, base: base.absoluteString)
        XCTAssertNil(art)
        XCTAssertNil(GameArt.cached(7, in: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("7.none").path))
    }
}
