import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import StepoverKit

final class GameArtTests: XCTestCase {
    private var cache: URL!

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: cache) }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    /// A CDN that answers each app id with a status and a body; any other id is "offline".
    private func cdn(_ answers: [Int: (Int, Data)]) -> GameArt.Load {
        { url in
            guard let id = answers.keys.first(where: { url.absoluteString.contains("/\($0)/") }) else { throw URLError(.notConnectedToInternet) }
            return (answers[id]!.1, answers[id]!.0)
        }
    }

    func testRemoteURL() {
        XCTAssertEqual(GameArt.remoteURL(1174180).absoluteString,
                       "https://cdn.cloudflare.steamstatic.com/steam/apps/1174180/library_600x900.jpg")
    }

    func testFetchCachesAndRemembersOnlyRealMisses() async throws {
        let art = await GameArt.fetch(1174180, into: cache, load: cdn([1174180: (200, jpeg)]))
        XCTAssertEqual(art?.lastPathComponent, "1174180.jpg")
        let again = await GameArt.fetch(1174180, into: cache, load: cdn([:]))      // offline now: the cached copy
        XCTAssertEqual(again?.lastPathComponent, "1174180.jpg")

        let missing = await GameArt.fetch(55230, into: cache, load: cdn([55230: (404, Data())]))
        XCTAssertNil(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("55230.none").path))
        let remembered = await GameArt.fetch(55230, into: cache, load: cdn([55230: (200, jpeg)]))
        XCTAssertNil(remembered)                                                   // not asked again
    }

    // Review I7: a server error or a captive portal's page is not "Steam has no cover".
    func testTransientAnswersAreNotRemembered() async throws {
        for (id, answer) in [(1, (500, Data())), (2, (429, Data())), (3, (200, Data("<html>Log in to Wi-Fi</html>".utf8)))] {
            let art = await GameArt.fetch(id, into: cache, load: cdn([id: answer]))
            XCTAssertNil(art)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("\(id).none").path), "\(id)")
        }
        let offline = await GameArt.fetch(4, into: cache, load: cdn([:]))
        XCTAssertNil(offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("4.none").path))
    }

    func testOldMissesAreAskedAgain() async throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let marker = cache.appendingPathComponent("7.none")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86400)], ofItemAtPath: marker.path)
        let art = await GameArt.fetch(7, into: cache, load: cdn([7: (200, jpeg)]))
        XCTAssertEqual(art?.lastPathComponent, "7.jpg")
    }

    // Review I6: the hero's tint is worked out off the main thread, from the file's bytes.
    func testCoverTintIsTheAverageColor() throws {
        let context = CGContext(data: nil, width: 8, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 6, width: 8, height: 6))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let tint = try XCTUnwrap(CoverTint.average(data as Data))
        XCTAssertEqual(tint.red, 0.5, accuracy: 0.08)
        XCTAssertEqual(tint.green, 0, accuracy: 0.08)
        XCTAssertEqual(tint.blue, 0.5, accuracy: 0.08)
        XCTAssertNil(CoverTint.average(Data("not an image".utf8)))
    }
}
