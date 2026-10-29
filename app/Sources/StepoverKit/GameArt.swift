import CoreGraphics
import Foundation
import ImageIO

/// A game's art from Steam, downloaded once into <root>/Art: the portrait cover (the Library's tiles), the wide key
/// art and the logo (couch mode's screen). No key needed. Only Steam saying it has none (404, 403) is remembered
/// (<id>.none, <id>-hero.none, <id>-logo.none, for 30 days); being offline, a server error or a captive portal's page
/// isn't, so the art arrives on a later launch.
public enum GameArt {
    public enum Kind: Sendable {
        case cover, hero, logo

        var remoteName: String { self == .cover ? "library_600x900.jpg" : self == .hero ? "library_hero.jpg" : "logo.png" }
        func fileName(_ appID: Int) -> String { self == .cover ? "\(appID).jpg" : self == .hero ? "\(appID)-hero.jpg" : "\(appID)-logo.png" }
        func missName(_ appID: Int) -> String { self == .cover ? "\(appID).none" : self == .hero ? "\(appID)-hero.none" : "\(appID)-logo.none" }
        /// The file's first bytes: JPEG, or PNG for the logo (its transparency is the point).
        var signature: [UInt8] { self == .logo ? [0x89, 0x50, 0x4E, 0x47] : [0xFF, 0xD8, 0xFF] }
    }

    public static let defaultBase = "https://cdn.cloudflare.steamstatic.com/steam/apps"

    /// A GET: the body and the HTTP status.
    public typealias Load = @Sendable (URL) async throws -> (Data, Int)

    public static let live: Load = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    public static var folder: URL { Paths.root.appendingPathComponent("Art") }

    public static func remoteURL(_ appID: Int, kind: Kind = .cover, base: String = defaultBase) -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/\(appID)/\(kind.remoteName)")!
    }

    public static func cached(_ appID: Int, kind: Kind = .cover, in folder: URL = folder) -> URL? {
        let file = folder.appendingPathComponent(kind.fileName(appID))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Downloads once: a cached file returns at once, a remembered miss returns nil without a request.
    public static func fetch(_ appID: Int, kind: Kind = .cover, into folder: URL = folder, base: String = defaultBase,
                             load: Load = live) async -> URL? {
        if let file = cached(appID, kind: kind, in: folder) { return file }
        let miss = folder.appendingPathComponent(kind.missName(appID))
        if let marked = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            if Date().timeIntervalSince(marked) < 30 * 86400 { return nil }
            try? FileManager.default.removeItem(at: miss)
        }
        guard let (body, status) = try? await load(remoteURL(appID, kind: kind, base: base)) else { return nil }   // offline
        if status == 404 || status == 403 {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        }
        // a server error, or a 200 that isn't the image (a captive portal's login page): try again later
        guard (200..<300).contains(status), body.starts(with: kind.signature) else { return nil }
        let file = folder.appendingPathComponent(kind.fileName(appID))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}

/// A cover's average color, for the hero's tint: a small thumbnail averaged pixel by pixel. Pure and cheap,
/// so the app runs it off the main thread.
public enum CoverTint {
    public static func average(_ data: Data) -> (red: Double, green: Double, blue: Double)? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1]); sum.2 += Double(pixels[i + 2])
        }
        let count = Double(width * height) * 255
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }
}

/// Whether a logo is mostly dark: the average lightness of its visible pixels, weighted by how opaque they are.
/// Couch mode shows a dark logo's game by its typed title, since the logo would vanish on the dark backdrop.
public enum LogoTone {
    public static func isDark(_ data: Data) -> Bool? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var light = 0.0, coverage = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 {
            // premultiplied: the channels already carry the alpha, so their sum is lightness times opacity
            light += (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
            coverage += Double(pixels[i + 3]) / 255
        }
        guard coverage > 0 else { return nil }
        return light / coverage < 0.4
    }
}
