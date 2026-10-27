import Foundation

/// The programs played most recently, newest first, in <root>/recent.json. Launcher.run records every
/// start, so games started from their Mac launchers count too. Kept apart from stepover.json so a
/// start from the command line never races the app's copy of a bottle's settings.
public enum RecentGames {
    public struct Entry: Codable, Equatable, Sendable {
        public var bottle: String
        public var program: String
        public var played: Date
    }

    static let limit = 50
    public static var file: URL { Paths.root.appendingPathComponent("recent.json") }

    public static func load(from file: URL = file) -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.sorted { $0.played > $1.played }
    }

    public static func record(_ program: String, bottle: String, at date: Date = Date(), in file: URL = file) {
        var entries = load(from: file).filter { !($0.bottle == bottle && $0.program == program) }
        entries.insert(Entry(bottle: bottle, program: program, played: date), at: 0)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(entries.prefix(limit))).write(to: file, options: .atomic)
    }
}
