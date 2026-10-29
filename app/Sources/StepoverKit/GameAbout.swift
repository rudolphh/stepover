import Foundation

/// What couch mode says about a game: Steam's short description, genres and release year. Fetched once from
/// Steam's store (appdetails) into <root>/Art/<id>-about.json, beside its art. Steam answering with nothing for
/// it is remembered (<id>-about.none, for 30 days); being offline or rate limited isn't.
public struct GameAbout: Codable, Equatable, Sendable {
    public var blurb: String
    public var genres: [String]
    public var year: String?

    public init(blurb: String, genres: [String], year: String?) {
        self.blurb = blurb; self.genres = genres; self.year = year
    }

    public static func fetch(_ appID: Int, into folder: URL = GameArt.folder,
                             fetch: SteamLookup.Fetch = SteamLookup.live) async -> GameAbout? {
        let file = folder.appendingPathComponent("\(appID)-about.json")
        if let data = try? Data(contentsOf: file), let about = try? JSONDecoder().decode(GameAbout.self, from: data) { return about }
        let miss = folder.appendingPathComponent("\(appID)-about.none")
        if let marked = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            if Date().timeIntervalSince(marked) < 30 * 86400 { return nil }
            try? FileManager.default.removeItem(at: miss)
        }
        guard let body = try? await fetch(SteamStore.appdetailsURL(appID)) else { return nil }   // offline, 429, 5xx
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let about = SteamStore.about(appdetails: body, appID: appID) else {
            // only Steam's own "nothing for this app" counts as a miss, not a captive portal's page
            if SteamStore.answered(appdetails: body, appID: appID) { FileManager.default.createFile(atPath: miss.path, contents: nil) }
            return nil
        }
        if let data = try? JSONEncoder().encode(about) { try? data.write(to: file, options: .atomic) }
        return about
    }

    /// Steam's short description without a promotional lead-in: Hi-Fi RUSH's opens with "Test your abilities in two
    /// new game modes, ...! Update!" before saying what the game is.
    static func cleaned(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let sentences = plain.replacingOccurrences(of: "([.!?]) ", with: "$1\n", options: .regularExpression)
            .split(separator: "\n").map(String.init)
        let promo = ["update", "now available", "out now", "new game mode", "dlc", "free weekend", "on sale"]
        let kept = sentences.drop { sentence in promo.contains { sentence.lowercased().contains($0) } }
        return kept.isEmpty ? plain : kept.joined(separator: " ")
    }
}

extension SteamStore {
    /// Nil when Steam has no data for the app or no description for it.
    public static func about(appdetails: Data, appID: Int) -> GameAbout? {
        guard let root = try? JSONSerialization.jsonObject(with: appdetails) as? [String: Any],
              let app = root[String(appID)] as? [String: Any], app["success"] as? Bool == true,
              let data = app["data"] as? [String: Any],
              let text = data["short_description"] as? String, !text.isEmpty else { return nil }
        let genres = (data["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        let date = (data["release_date"] as? [String: Any])?["date"] as? String ?? ""
        let year = date.range(of: "[0-9]{4}", options: .regularExpression).map { String(date[$0]) }
        return GameAbout(blurb: GameAbout.cleaned(text), genres: genres, year: year)
    }

    /// Whether the body is Steam's answer for the app at all (with or without data), not some other page.
    static func answered(appdetails: Data, appID: Int) -> Bool {
        ((try? JSONSerialization.jsonObject(with: appdetails)) as? [String: Any])?[String(appID)] != nil
    }
}
