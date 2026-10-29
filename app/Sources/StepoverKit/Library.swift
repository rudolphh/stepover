import Foundation

/// One tile in the Library: a program in a bottle, a game installed through Steam, the Steam client, or a game on
/// its way in from an installer or folder.
public struct LibraryGame: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case program(Program), steamGame(SteamApp), steamClient(Program), install(InstallJob) }
    public var id: String                 // "<bottle id>|<program name>", "<bottle id>|steam:<appid>", "<bottle id>|steam", "install:<job id>"
    public var name: String
    public var bottle: Bottle
    public var kind: Kind
    public var entry: GameEntry?          // the games list's entry, matched on the Mac
    public var lastPlayed: Date?
    public var steamAppID: Int?           // the Steam game's own id, else the entry's
    /// What Play runs: the program, or the Steam client with -applaunch, named after the game (RecentGames).
    public var launch: Program
    /// A line about how the game came in, for a game added from a folder whose add-on didn't install (spec D1b).
    public var note: String? = nil

    public var isSteamClient: Bool { if case .steamClient = kind { return true } else { return false } }
    public var install: InstallJob? { if case .install(let job) = kind { return job } else { return nil } }
}

/// Which games the Library shows (spec: Games appear by themselves), matched to the games list on the Mac.
public enum Library {
    public static func games(bottles: [(bottle: Bottle, config: BottleConfig)], steamApps: (Bottle) -> [SteamApp],
                             index: GameIndex, recent: [RecentGames.Entry], learned: GameIndex? = nil,
                             installs: [InstallJob] = []) -> [LibraryGame] {
        func played(_ bottle: Bottle, _ name: String) -> Date? {
            recent.filter { $0.bottle == bottle.name && $0.program == name }.map(\.played).max()
        }
        var out: [LibraryGame] = []
        // a game still on its way in has only its install tile, never a Play tile (spec anti-goals)
        let unfinished = InstallQueue(jobs: installs).unfinishedBottles
        let notes = Dictionary(installs.compactMap { job -> (String, String)? in
            guard let bottle = job.bottle, case .done(let addOn?) = job.stage else { return nil }
            return (bottle, InstallStage.done(addOnFailed: addOn).text)
        }, uniquingKeysWith: { a, _ in a })
        for (bottle, config) in bottles where !unfinished.contains(bottle.name) {
            let apps = steamApps(bottle)
            let client = config.programs.first { fileName($0.exe).lowercased() == "steam.exe" } ?? SteamLibrary.client(in: bottle)
            let games = apps.filter { !nonGames.contains($0.id) }
            for program in config.programs where fileName(program.exe).lowercased() != "steam.exe" {
                // a launcher made from a Steam game's own exe is that Steam game's tile (when Steam can start it)
                let exe = program.exe.lowercased()
                if client != nil, games.contains(where: { exe.hasPrefix($0.windowsFolder.lowercased() + "\\") }) { continue }
                let entry = index.match(name: program.name, exe: fileName(program.exe)) ?? index.match(name: bottle.name, exe: nil)
                    ?? learned?.match(name: program.name, exe: nil)
                out.append(LibraryGame(id: "\(bottle.id)|\(program.name)", name: program.name, bottle: bottle, kind: .program(program),
                                       entry: entry, lastPlayed: played(bottle, program.name), steamAppID: entry?.steam, launch: program,
                                       note: notes[bottle.name]))
            }
            if let client {
                for app in games {
                    let launch = Program(name: app.name, exe: client.exe, args: client.args + ["-applaunch", String(app.id)],
                                         workdir: client.workdir, graphics: client.graphics, env: client.env)
                    let entry = index.entry(steam: app.id) ?? index.match(name: app.name, exe: nil) ?? learned?.entry(steam: app.id)
                    out.append(LibraryGame(id: "\(bottle.id)|steam:\(app.id)", name: app.name, bottle: bottle, kind: .steamGame(app),
                                           entry: entry, lastPlayed: played(bottle, app.name), steamAppID: app.id, launch: launch))
                }
                out.append(LibraryGame(id: "\(bottle.id)|steam", name: "Steam", bottle: bottle, kind: .steamClient(client),
                                       entry: nil, lastPlayed: played(bottle, client.name), steamAppID: nil, launch: client))
            }
        }
        let coming = installs.filter { !$0.isDone }.sorted { $0.added > $1.added }.map { job -> LibraryGame in
            let entry = job.steam.flatMap { index.entry(steam: $0) } ?? index.match(name: job.name, exe: nil)
                ?? learned?.match(name: job.name, exe: nil)
            return LibraryGame(id: "install:\(job.id)", name: job.name,
                               bottle: Bottle(url: Paths.bottles.appendingPathComponent(job.bottle ?? job.name)), kind: .install(job),
                               entry: entry, lastPlayed: nil, steamAppID: job.steam ?? entry?.steam, launch: Program(name: job.name, exe: ""))
        }
        // games on their way in first, newest first; then played games newest first, then by name; the Steam client tiles last
        return coming + out.sorted { a, b in
            if a.isSteamClient != b.isSteamClient { return !a.isSteamClient }
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Games the list doesn't know and this Mac hasn't looked up on Steam yet (or whose miss is over 30 days
    /// old), by name; a Steam game also carries its app id.
    public static func lookups(_ games: [LibraryGame], learned: LearnedGames, today: String) -> [(name: String, appID: Int?)] {
        var seen = Set<String>()
        return games.compactMap { game -> (name: String, appID: Int?)? in
            guard game.entry == nil, !game.isSteamClient else { return nil }
            let key = GameName.normalized(game.name)
            if let missed = learned.misses[key], LearnedGames.days(from: missed, to: today) <= 30 { return nil }
            guard seen.insert(key).inserted else { return nil }
            if case .steamGame(let app) = game.kind { return (game.name, app.id) }
            return (game.name, nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Steam apps that aren't games: Steamworks Common Redistributables, which Steam installs for nearly everyone.
    static let nonGames: Set<Int> = [228980]

    static func fileName(_ windowsPath: String) -> String {
        String(windowsPath.split(separator: "\\").last ?? Substring(windowsPath))
    }
}

/// How a tile's line looks: each paired with its words, never shown by color alone.
public enum TileTone: Sendable { case good, maybe, caution, bad, mac, unknown }

extension TileTone {
    public typealias RGB = (red: Double, green: Double, blue: Double)

    /// The tone's text color, chosen so it reads at 4.5:1 on its own pill in a light or dark window.
    public func rgb(dark: Bool) -> RGB {
        func hex(_ value: Int) -> RGB { (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255) }
        switch self {
        case .good: return hex(dark ? 0x30D158 : 0x16692C)
        case .maybe: return hex(dark ? 0x64A8FF : 0x0055B3)
        case .caution: return hex(dark ? 0xFF9F0A : 0x7A3F00)
        case .bad: return hex(dark ? 0xFF6B60 : 0x9E1F18)
        case .mac: return hex(dark ? 0xD58BFF : 0x7A33B0)
        case .unknown: return hex(dark ? 0xA1A1A6 : 0x5E5E63)
        }
    }

    /// The pill's background: the tone at this opacity over the window.
    public var pillAlpha: Double { self == .unknown ? 0.12 : 0.16 }

    public static func windowBackground(dark: Bool) -> RGB { dark ? (0.118, 0.118, 0.118) : (0.925, 0.925, 0.925) }

    public static func blend(_ color: RGB, over background: RGB, alpha: Double) -> RGB {
        (color.red * alpha + background.red * (1 - alpha), color.green * alpha + background.green * (1 - alpha),
         color.blue * alpha + background.blue * (1 - alpha))
    }

    /// WCAG contrast ratio.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: RGB) -> Double { 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue) }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension PlayVerdict.Kind {
    /// The tile's line; the detail panel shows the full headline.
    public var short: String {
        switch self {
        case .yourRuns: return "Runs on this Mac"
        case .yourProblems: return "Had problems on this Mac"
        case .macVersion: return "There's a Mac version"
        case .doesntRun: return "Doesn't run on Mac yet"
        case .antiCheatBlocked: return "Won't run: anti-cheat"
        case .singlePlayerOnly: return "Single-player only"
        case .playsGreat: return "Plays great"
        case .playable: return "Playable"
        case .startsWithProblems: return "Starts, with problems"
        case .shouldPlay: return "Should play"
        case .probablyWontRun: return "Probably won't run"
        case .notTested: return "Not tested yet"
        }
    }

    public var tone: TileTone {
        switch self {
        case .yourRuns, .playsGreat, .playable: return .good
        case .shouldPlay: return .maybe
        case .yourProblems, .singlePlayerOnly, .startsWithProblems: return .caution
        case .doesntRun, .antiCheatBlocked, .probablyWontRun: return .bad
        case .macVersion: return .mac
        case .notTested: return .unknown
        }
    }
}

extension ControllerVerdict {
    public var short: String {
        switch self {
        case .yours: return "Played with a controller"
        case .full: return "Full controller"
        case .worksMenusMouse: return "Controller, mouse for menus"
        case .partial: return "Partial controller"
        case .keyboardMouse: return "Keyboard and mouse"
        }
    }
}

/// What the Library remembers: <root>/library.json.
public struct LibraryState: Codable, Sendable {
    public var hidden: [String]           // LibraryGame ids

    public init(hidden: [String] = []) { self.hidden = hidden }

    public static var file: URL { Paths.root.appendingPathComponent("library.json") }

    public static func load(from file: URL = file) -> LibraryState {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LibraryState.self, from: $0) } ?? LibraryState()
    }

    public func save(to file: URL = file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
