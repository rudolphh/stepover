import Foundation

/// What Stepover knows about games before anyone plays them here: Mac test results, anti-cheat, Steam and
/// Steam Deck facts, and which games have a fix. Built daily by the Games list workflow (games-list) and
/// published as the games.json asset of the rolling release "games-list"; the app keeps the last copy it
/// fetched in <root>/games-list.json and falls back to the snapshot bundled in Stepover.app.
public struct GamesList: Codable, Sendable {
    public static let supportedFormat = 1
    public var format: Int
    public var generated: String          // ISO 8601, when CI built it
    public var credits: [String]          // attribution lines (license obligations)
    public var games: [GameEntry]

    public init(format: Int, generated: String, credits: [String], games: [GameEntry]) {
        self.format = format; self.generated = generated; self.credits = credits; self.games = games
    }
}

public struct GameEntry: Codable, Hashable, Sendable {
    public var id: String                 // "steam:<appid>", else "agw:<page title>", else "acy:<slug>"
    public var name: String
    public var names: [String]            // other names it goes by, for matching
    public var steam: Int?
    public var epic: String?              // "<namespace>/<slug>" from AreWeAntiCheatYet
    public var exes: [String]             // exe file names from Stepover's fix list
    public var agwPage: String?
    public var mac: MacTests?
    public var antiCheat: AntiCheat?
    public var store: StoreFacts?         // Steam store facts
    public var deck: DeckFacts?
    public var fix: Bool                  // Stepover's fix list has a fix for it

    public init(id: String, name: String, names: [String] = [], steam: Int? = nil, epic: String? = nil, exes: [String] = [],
                agwPage: String? = nil, mac: MacTests? = nil, antiCheat: AntiCheat? = nil, store: StoreFacts? = nil,
                deck: DeckFacts? = nil, fix: Bool = false) {
        self.id = id; self.name = name; self.names = names; self.steam = steam; self.epic = epic; self.exes = exes
        self.agwPage = agwPage; self.mac = mac; self.antiCheat = antiCheat; self.store = store; self.deck = deck; self.fix = fix
    }
}

/// AppleGamingWiki's ratings, worst to best.
public enum MacRating: String, Codable, Sendable, Comparable, CaseIterable {
    case unplayable, runs, playable, perfect

    public static func < (a: MacRating, b: MacRating) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public struct MacTest: Codable, Hashable, Sendable {
    public var rating: MacRating
    public var device: String?
    public var method: String?            // e.g. "Crossover 25.0"
    public var date: String?              // "2025-05-05" or "2025-05"

    public init(rating: MacRating, device: String? = nil, method: String? = nil, date: String? = nil) {
        self.rating = rating; self.device = device; self.method = method; self.date = date
    }
}

public struct MacTests: Codable, Hashable, Sendable {
    public var native: MacTest?
    public var rosetta: MacTest?
    public var crossover: MacTest?
    public var wine: MacTest?

    public init(native: MacTest? = nil, rosetta: MacTest? = nil, crossover: MacTest? = nil, wine: MacTest? = nil) {
        self.native = native; self.rosetta = rosetta; self.crossover = crossover; self.wine = wine
    }
}

public struct AntiCheat: Codable, Hashable, Sendable {
    public var names: [String]            // "Easy Anti-Cheat", ...
    public var status: String             // AreWeAntiCheatYet's Linux status, kept for reference

    public init(names: [String], status: String) { self.names = names; self.status = status }
}

public enum ControllerCategory: String, Codable, Sendable { case full, partial }

public struct StoreFacts: Codable, Hashable, Sendable {
    public var macVersion: Bool
    public var singlePlayer: Bool
    public var controller: ControllerCategory?
    public var checked: String            // "2026-10-28"

    public init(macVersion: Bool, singlePlayer: Bool, controller: ControllerCategory?, checked: String) {
        self.macVersion = macVersion; self.singlePlayer = singlePlayer; self.controller = controller; self.checked = checked
    }
}

public enum DeckCategory: Int, Codable, Sendable { case unknown = 0, unsupported, playable, verified }

public struct DeckFacts: Codable, Hashable, Sendable {
    public var category: DeckCategory
    public var controllerWorks: Bool
    public var checked: String

    public init(category: DeckCategory, controllerWorks: Bool, checked: String) {
        self.category = category; self.controllerWorks = controllerWorks; self.checked = checked
    }
}

extension GamesList {
    /// Nil for anything that isn't a games list this app can read, and for an empty one.
    public static func decode(_ data: Data) -> GamesList? {
        guard let list = try? JSONDecoder().decode(GamesList.self, from: data),
              list.format <= supportedFormat, !list.games.isEmpty else { return nil }
        return list
    }

    public static var cacheFile: URL { Paths.root.appendingPathComponent("games-list.json") }

    public static func defaultSource(repository: String) -> String {
        "https://github.com/\(repository)/releases/download/games-list/games.json"
    }

    /// STEPOVER_GAMES_LIST (a URL or a file path), else the games-list release of the source repository.
    public static var source: String {
        if let value = Paths.env["STEPOVER_GAMES_LIST"], !value.isEmpty { return value }
        return defaultSource(repository: Paths.sourceRepository)
    }

    /// The snapshot in Stepover.app/Contents/Resources/games.json (release builds).
    public static func bundled(bundle: Bundle? = Paths.appBundle) -> GamesList? {
        // the path, not url(forResource:), whose lookups Bundle caches (as FixLibrary does)
        guard let url = bundle?.resourceURL?.appendingPathComponent("games.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The cached list, else the bundled snapshot, else an empty list.
    public static func load(cache: URL = cacheFile, bundled: GamesList? = bundled()) -> GamesList {
        if let data = try? Data(contentsOf: cache), let list = decode(data) { return list }
        return bundled ?? GamesList(format: supportedFormat, generated: "", credits: [], games: [])
    }

    /// The list is fetched at most once a day: true when there is no cache or it is over 24 hours old.
    public static func needsRefresh(cache: URL = cacheFile, now: Date = Date()) -> Bool {
        guard let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return true }
        return now.timeIntervalSince(modified) > 24 * 3600
    }

    /// Reads the list and replaces the cache only when what arrived is a list this app can read.
    /// Offline, an error page or a broken file leave the cache as it was. Never throws.
    @discardableResult
    public static func fetch(from source: String = source, to cache: URL = cacheFile) async -> Bool {
        let data: Data
        if !source.contains("://") || source.hasPrefix("file://") {
            let file = source.hasPrefix("file://") ? URL(string: source) : URL(fileURLWithPath: source)
            guard let file, let read = try? Data(contentsOf: file) else { return false }
            data = read
        } else {
            guard let url = URL(string: source) else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (body, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            data = body
        }
        guard decode(data) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cache, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
