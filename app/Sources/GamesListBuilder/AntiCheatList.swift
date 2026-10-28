import Foundation

/// One game in AreWeAntiCheatYet's games.json (MIT).
public struct AntiCheatGame: Equatable, Sendable {
    public var name: String
    public var slug: String
    public var status: String
    public var anticheats: [String]
    public var steam: Int?
    public var epic: String?              // "<namespace>/<slug>"

    public init(name: String, slug: String, status: String, anticheats: [String], steam: Int?, epic: String?) {
        self.name = name; self.slug = slug; self.status = status; self.anticheats = anticheats; self.steam = steam; self.epic = epic
    }
}

public enum AntiCheatList {
    private struct Raw: Decodable {
        struct Stores: Decodable {
            struct Epic: Decodable { var namespace: String; var slug: String }
            var steam: String?
            var epic: Epic?
        }
        var name: String
        var slug: String
        var status: String
        var anticheats: [String]?
        var storeIds: Stores?
    }

    /// Nil when the data isn't AreWeAntiCheatYet's games array.
    public static func decode(_ data: Data) -> [AntiCheatGame]? {
        guard let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return nil }
        return raw.map {
            AntiCheatGame(name: $0.name, slug: $0.slug, status: $0.status, anticheats: $0.anticheats ?? [],
                          steam: $0.storeIds?.steam.flatMap { Int($0) },
                          epic: $0.storeIds?.epic.map { "\($0.namespace)/\($0.slug)" })
        }
    }
}
