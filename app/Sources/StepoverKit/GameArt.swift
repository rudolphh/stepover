import Foundation

/// Cover art for the Library: Steam's portrait capsule for an app id, downloaded once into <root>/Art.
/// No key needed. A game Steam has no capsule for is remembered (<id>.none) so it isn't asked for again;
/// being offline isn't, so the art arrives on a later launch.
public enum GameArt {
    public static let defaultBase = "https://cdn.cloudflare.steamstatic.com/steam/apps"

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
    public static func fetch(_ appID: Int, into folder: URL = folder, base: String = defaultBase) async -> URL? {
        if let file = cached(appID, in: folder) { return file }
        let miss = folder.appendingPathComponent("\(appID).none")
        if FileManager.default.fileExists(atPath: miss.path) { return nil }
        var request = URLRequest(url: remoteURL(appID, base: base))
        request.timeoutInterval = 20
        let body: Data
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                remember(miss)   // Steam has no capsule for it
                return nil
            }
            body = data
        } catch {
            if (error as? URLError)?.code == .fileDoesNotExist { remember(miss) }
            return nil           // offline or a timeout: ask again next time
        }
        guard body.starts(with: [0xFF, 0xD8, 0xFF]) else {
            remember(miss)
            return nil
        }
        let file = folder.appendingPathComponent("\(appID).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func remember(_ miss: URL) {
        try? FileManager.default.createDirectory(at: miss.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: miss.path, contents: nil)
    }
}
