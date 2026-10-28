import Foundation

/// Installed games the games list doesn't know, looked up once on Steam's store from this Mac: only the
/// game's name (or its Steam app id) is sent, and only an exact single match is kept. <root>/learned-games.json.
public struct LearnedGames: Codable, Sendable {
    public var entries: [GameEntry]
    /// Normalized names Steam had no exact match for, with the date; asked again after 30 days.
    public var misses: [String: String]

    public init(entries: [GameEntry] = [], misses: [String: String] = [:]) { self.entries = entries; self.misses = misses }

    public static var file: URL { Paths.root.appendingPathComponent("learned-games.json") }

    public static func load(from file: URL = file) -> LearnedGames {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LearnedGames.self, from: $0) } ?? LearnedGames()
    }

    public func save(to file: URL = file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    public var index: GameIndex { GameIndex(GamesList(format: GamesList.supportedFormat, generated: "", credits: [], games: entries)) }

    static func days(from: String, to: String) -> Int {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        guard let a = format.date(from: from), let b = format.date(from: to) else { return .max }
        return Int(b.timeIntervalSince(a) / 86400)
    }
}

public enum SteamLookup {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let live: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return data
    }

    /// The game's Steam facts, by its app id or by an exact name search. Nil when Steam has no such game or no
    /// facts for it (remember the miss); throws when Steam couldn't be reached (don't).
    public static func learn(name: String, appID: Int?, today: String, fetch: Fetch = live) async throws -> GameEntry? {
        var id = appID
        if id == nil {
            guard let results = SteamStore.searchResults(try await fetch(SteamStore.searchURL(name))) else {
                throw URLError(.cannotParseResponse)
            }
            id = SteamStore.exactMatch(results, for: name)
        }
        guard let id, let (steamName, facts) = SteamStore.storeFacts(appdetails: try await fetch(SteamStore.appdetailsURL(id)),
                                                                     appID: id, checked: today) else { return nil }
        let deck = (try? await fetch(SteamStore.deckReportURL(id))).flatMap { SteamStore.deckFacts(report: $0, checked: today) }
        return GameEntry(id: "steam:\(id)", name: steamName, names: steamName == name ? [] : [name], steam: id, store: facts, deck: deck)
    }
}
