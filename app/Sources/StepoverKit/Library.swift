import Foundation

/// One tile in the Library: a program in a bottle, a game installed through Steam, or the Steam client.
public struct LibraryGame: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case program(Program), steamGame(SteamApp), steamClient(Program) }
    public var id: String                 // "<bottle id>|<program name>", "<bottle id>|steam:<appid>", "<bottle id>|steam"
    public var name: String
    public var bottle: Bottle
    public var kind: Kind
    public var entry: GameEntry?          // the games list's entry, matched on the Mac
    public var lastPlayed: Date?
    public var steamAppID: Int?           // the Steam game's own id, else the entry's
    /// What Play runs: the program, or the Steam client with -applaunch, named after the game (RecentGames).
    public var launch: Program

    public var isSteamClient: Bool { if case .steamClient = kind { return true } else { return false } }
}

/// Which games the Library shows (spec: Games appear by themselves), matched to the games list on the Mac.
public enum Library {
    public static func games(bottles: [(bottle: Bottle, config: BottleConfig)], steamApps: (Bottle) -> [SteamApp],
                             index: GameIndex, recent: [RecentGames.Entry]) -> [LibraryGame] {
        func played(_ bottle: Bottle, _ name: String) -> Date? {
            recent.filter { $0.bottle == bottle.name && $0.program == name }.map(\.played).max()
        }
        var out: [LibraryGame] = []
        for (bottle, config) in bottles {
            let apps = steamApps(bottle)
            let client = config.programs.first { fileName($0.exe).lowercased() == "steam.exe" } ?? SteamLibrary.client(in: bottle)
            for program in config.programs where fileName(program.exe).lowercased() != "steam.exe" {
                // a launcher made from a Steam game's own exe is that Steam game's tile
                let exe = program.exe.lowercased()
                if apps.contains(where: { exe.hasPrefix($0.windowsFolder.lowercased() + "\\") }) { continue }
                let entry = index.match(name: program.name, exe: fileName(program.exe)) ?? index.match(name: bottle.name, exe: nil)
                out.append(LibraryGame(id: "\(bottle.id)|\(program.name)", name: program.name, bottle: bottle, kind: .program(program),
                                       entry: entry, lastPlayed: played(bottle, program.name), steamAppID: entry?.steam, launch: program))
            }
            if let client {
                for app in apps {
                    let launch = Program(name: app.name, exe: client.exe, args: ["-applaunch", String(app.id)])
                    let entry = index.entry(steam: app.id) ?? index.match(name: app.name, exe: nil)
                    out.append(LibraryGame(id: "\(bottle.id)|steam:\(app.id)", name: app.name, bottle: bottle, kind: .steamGame(app),
                                           entry: entry, lastPlayed: played(bottle, app.name), steamAppID: app.id, launch: launch))
                }
                out.append(LibraryGame(id: "\(bottle.id)|steam", name: "Steam", bottle: bottle, kind: .steamClient(client),
                                       entry: nil, lastPlayed: played(bottle, client.name), steamAppID: nil, launch: client))
            }
        }
        // played games newest first, then by name; the Steam client tiles last
        return out.sorted { a, b in
            if a.isSteamClient != b.isSteamClient { return !a.isSteamClient }
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    static func fileName(_ windowsPath: String) -> String {
        String(windowsPath.split(separator: "\\").last ?? Substring(windowsPath))
    }
}

/// How a tile's line looks: each paired with its words, never shown by color alone.
public enum TileTone: Sendable { case good, maybe, caution, bad, mac, unknown }

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
