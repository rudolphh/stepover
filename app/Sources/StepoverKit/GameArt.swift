import CoreGraphics
import Foundation
import ImageIO

/// Cover art for the Library: Steam's portrait capsule for an app id, downloaded once into <root>/Art.
/// No key needed. Only Steam saying it has no capsule (404, 403) is remembered (<id>.none, for 30 days);
/// being offline, a server error or a captive portal's page isn't, so the art arrives on a later launch.
public enum GameArt {
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

    public static func remoteURL(_ appID: Int, base: String = defaultBase) -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/\(appID)/library_600x900.jpg")!
    }

    public static func cached(_ appID: Int, in folder: URL = folder) -> URL? {
        let file = folder.appendingPathComponent("\(appID).jpg")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Downloads once: a cached file returns at once, a remembered miss returns nil without a request.
    public static func fetch(_ appID: Int, into folder: URL = folder, base: String = defaultBase, load: Load = live) async -> URL? {
        if let file = cached(appID, in: folder) { return file }
        let miss = folder.appendingPathComponent("\(appID).none")
        if let marked = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            if Date().timeIntervalSince(marked) < 30 * 86400 { return nil }
            try? FileManager.default.removeItem(at: miss)
        }
        guard let (body, status) = try? await load(remoteURL(appID, base: base)) else { return nil }   // offline
        if status == 404 || status == 403 {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        }
        // a server error, or a 200 that isn't a JPEG (a captive portal's login page): try again later
        guard (200..<300).contains(status), body.starts(with: [0xFF, 0xD8, 0xFF]) else { return nil }
        let file = folder.appendingPathComponent("\(appID).jpg")
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
