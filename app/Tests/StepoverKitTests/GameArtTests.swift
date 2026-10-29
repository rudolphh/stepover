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

    /// A CDN that answers each app id with a status and a body, beside a store list with no art for any game; any
    /// other id is "offline".
    private func cdn(_ answers: [Int: (Int, Data)]) -> GameArt.Load {
        { url in
            if url.absoluteString.contains("IStoreBrowseService/GetItems") { return (Data(#"{"response":{"store_items":[]}}"#.utf8), 200) }
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

    // Couch mode's look: the game's key art behind it and its logo as the title, cached like covers
    func testKeyArtAndLogo() async throws {
        XCTAssertEqual(GameArt.remoteURL(1174180, kind: .hero).absoluteString,
                       "https://cdn.cloudflare.steamstatic.com/steam/apps/1174180/library_hero.jpg")
        XCTAssertEqual(GameArt.remoteURL(1174180, kind: .logo).absoluteString,
                       "https://cdn.cloudflare.steamstatic.com/steam/apps/1174180/logo.png")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let hero = await GameArt.fetch(1174180, kind: .hero, into: cache, load: cdn([1174180: (200, jpeg)]))
        XCTAssertEqual(hero?.lastPathComponent, "1174180-hero.jpg")
        let logo = await GameArt.fetch(1174180, kind: .logo, into: cache, load: cdn([1174180: (200, png)]))
        XCTAssertEqual(logo?.lastPathComponent, "1174180-logo.png")
        XCTAssertEqual(GameArt.cached(1174180, kind: .logo, in: cache)?.lastPathComponent, "1174180-logo.png")
        let notPNG = await GameArt.fetch(2, kind: .logo, into: cache, load: cdn([2: (200, jpeg)]))
        XCTAssertNil(notPNG)
        let none = await GameArt.fetch(3, kind: .hero, into: cache, load: cdn([3: (404, Data())]))
        XCTAssertNil(none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("3-hero.none").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("3.none").path))   // the cover is still asked for
    }

    // Newer games keep their cover and key art at hashed paths only Steam's store lists (GetItems); the fixed path
    // 404s for them. Castlevania: Belmont's Curse (2026), trimmed from Steam's real answer.
    private let castlevaniaItems = Data(#"{"response":{"store_items":[{"item_type":0,"id":4231820,"success":1,"visible":true,"name":"Castlevania: Belmont's Curse","appid":4231820,"type":0,"assets":{"asset_url_format":"steam/apps/4231820/${FILENAME}?t=1793067818","header":"6b65aec2c398006aea8b76e1463cc34d0e4ba68b/header.jpg","library_capsule":"a296479a772d37cfb6c36c59059b72d663abca38/library_capsule.jpg","library_hero":"a86259a3a341818b144f97400c4cc5b3db0e708e/library_hero.jpg","last_modified":1793067818}}]}}"#.utf8)
    private let unknownItems = Data(#"{"response":{"store_items":[{"item_type":0,"id":8,"success":15,"visible":false,"name":"","appid":0}]}}"#.utf8)

    func testStoreAssets() {
        let assets = SteamStore.assets(castlevaniaItems, appID: 4231820)
        XCTAssertEqual(assets?["library_capsule"], "steam/apps/4231820/a296479a772d37cfb6c36c59059b72d663abca38/library_capsule.jpg?t=1793067818")
        XCTAssertEqual(assets?["library_hero"], "steam/apps/4231820/a86259a3a341818b144f97400c4cc5b3db0e708e/library_hero.jpg?t=1793067818")
        XCTAssertNil(assets?["last_modified"])
        XCTAssertEqual(SteamStore.assets(unknownItems, appID: 8), [:])                 // Steam has nothing for it
        XCTAssertEqual(SteamStore.assets(castlevaniaItems, appID: 5), [:])            // an answer about another game
        XCTAssertNil(SteamStore.assets(Data("<html>Log in to Wi-Fi</html>".utf8), appID: 4231820))
        XCTAssertTrue(SteamStore.itemsURL(4231820).absoluteString.hasPrefix("https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json="))
    }

    /// Steam's store and CDN: GetItems answers `items`, the hashed files in `files` answer with theirs, the rest 404.
    private func store(_ items: Result<(Data, Int), URLError>, files: [String: (Int, Data)] = [:]) -> GameArt.Load {
        { url in
            if url.absoluteString.contains("IStoreBrowseService/GetItems") { return try items.get() }
            if let file = files.keys.first(where: { url.absoluteString.contains($0) }) { return (files[file]!.1, files[file]!.0) }
            return (Data(), 404)
        }
    }

    func testNewerGamesArtComesFromTheStoresHashedPaths() async throws {
        let files = ["shared.fastly.steamstatic.com/store_item_assets/steam/apps/4231820/a296479a772d37cfb6c36c59059b72d663abca38/library_capsule.jpg?t=": (200, jpeg),
                     "shared.fastly.steamstatic.com/store_item_assets/steam/apps/4231820/a86259a3a341818b144f97400c4cc5b3db0e708e/library_hero.jpg?t=": (200, jpeg)]
        let steam = store(.success((castlevaniaItems, 200)), files: files)
        let cover = await GameArt.fetch(4231820, into: cache, load: steam)
        XCTAssertEqual(cover?.lastPathComponent, "4231820.jpg")
        let hero = await GameArt.fetch(4231820, kind: .hero, into: cache, load: steam)
        XCTAssertEqual(hero?.lastPathComponent, "4231820-hero.jpg")
        let logo = await GameArt.fetch(4231820, kind: .logo, into: cache, load: steam)   // the store doesn't list logos
        XCTAssertNil(logo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("4231820-logo.none").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("4231820.none").path))
    }

    // Only the store saying it has no art, or its file 404ing, is a miss to remember; the store or the file being
    // unreachable or failing is asked again on a later launch.
    func testTheStoresAnswerDecidesTheMiss() async throws {
        let hashed = "store_item_assets/steam/apps/4231820/a296479a772d37cfb6c36c59059b72d663abca38/library_capsule.jpg"
        let cases: [(id: Int, load: GameArt.Load, remembered: Bool)] = [
            (8, store(.success((unknownItems, 200))), true),
            (4231820, store(.success((castlevaniaItems, 200)), files: [hashed: (404, Data())]), true),
            (4231820, store(.success((castlevaniaItems, 200)), files: [hashed: (500, Data())]), false),
            (4231820, store(.success((castlevaniaItems, 200)), files: [hashed: (200, Data("<html>Log in to Wi-Fi</html>".utf8))]), false),
            (4231820, store(.success((Data(), 500))), false),
            (4231820, store(.success((Data("<html>Log in to Wi-Fi</html>".utf8), 200))), false),
            (4231820, store(.failure(URLError(.notConnectedToInternet))), false),
        ]
        for (n, test) in cases.enumerated() {
            let folder = cache.appendingPathComponent("\(n)")
            let art = await GameArt.fetch(test.id, into: folder, load: test.load)
            XCTAssertNil(art, "\(n)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(test.id).none").path), test.remembered, "\(n)")
        }
    }

    func testAboutTheGameFromSteam() async throws {
        let hifi = Data(#"{"1817230":{"success":true,"data":{"type":"game","name":"Hi-Fi RUSH","short_description":"Test your abilities in two new game modes, uncover new rewards and even a few secrets in the Arcade Challenge! Update! Feel the beat as wannabe rockstar Chai and his ragtag team fight against an evil megacorp in a world that syncs to the music.","genres":[{"id":"1","description":"Action"}],"release_date":{"coming_soon":false,"date":"Jan 25, 2023"}}}}"#.utf8)
        let about = try XCTUnwrap(SteamStore.about(appdetails: hifi, appID: 1817230))
        XCTAssertEqual(about.blurb, "Feel the beat as wannabe rockstar Chai and his ragtag team fight against an evil megacorp in a world that syncs to the music.")
        XCTAssertEqual(about.genres, ["Action"])
        XCTAssertEqual(about.year, "2023")
        let rdr2 = Data(#"{"1174180":{"success":true,"data":{"type":"game","name":"Red Dead Redemption 2","short_description":"Arthur Morgan and the Van der Linde Gang are outlaws on the run. With federal agents &amp; bounty hunters on their heels, the gang must &quot;survive&quot;.","genres":[{"id":"1","description":"Action"},{"id":"25","description":"Adventure"}],"release_date":{"date":"5 Dec, 2019"}}}}"#.utf8)
        let red = try XCTUnwrap(SteamStore.about(appdetails: rdr2, appID: 1174180))
        XCTAssertEqual(red.blurb, "Arthur Morgan and the Van der Linde Gang are outlaws on the run. With federal agents & bounty hunters on their heels, the gang must \"survive\".")
        XCTAssertEqual(red.genres, ["Action", "Adventure"])
        XCTAssertEqual(red.year, "2019")
        XCTAssertNil(SteamStore.about(appdetails: Data(#"{"5":{"success":false}}"#.utf8), appID: 5))

        // fetched once, then read from the cache; Steam having nothing is remembered, being offline isn't
        let answers: [Int: Data] = [1817230: hifi, 5: Data(#"{"5":{"success":false}}"#.utf8)]
        let steam: SteamLookup.Fetch = { url in
            guard let id = answers.keys.first(where: { url.absoluteString.contains("appids=\($0)&") }) else { throw URLError(.notConnectedToInternet) }
            return answers[id]!
        }
        let fetched = await GameAbout.fetch(1817230, into: cache, fetch: steam)
        XCTAssertEqual(fetched?.genres, ["Action"])
        let offline: SteamLookup.Fetch = { _ in throw URLError(.notConnectedToInternet) }
        let cached = await GameAbout.fetch(1817230, into: cache, fetch: offline)
        XCTAssertEqual(cached?.year, "2023")
        let missing = await GameAbout.fetch(5, into: cache, fetch: steam)
        XCTAssertNil(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("5-about.none").path))
        let unreachable = await GameAbout.fetch(6, into: cache, fetch: offline)
        XCTAssertNil(unreachable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("6-about.none").path))
    }

    // Sainthood's logo is dark ink on a clear background: on couch mode's dark backdrop it would vanish, so a dark
    // logo gives way to the typed title
    func testDarkLogos() throws {
        func logo(_ gray: CGFloat) -> Data {
            let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            context.fill(CGRect(x: 2, y: 2, width: 16, height: 6))           // the lettering; the rest stays clear
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            _ = CGImageDestinationFinalize(destination)
            return data as Data
        }
        XCTAssertEqual(LogoTone.isDark(logo(0.15)), true)
        XCTAssertEqual(LogoTone.isDark(logo(0.9)), false)
        XCTAssertNil(LogoTone.isDark(Data("not an image".utf8)))
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
