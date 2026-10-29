import Foundation

/// A dropped game, as recognized: the name to show and, when the games list knows it, its entry.
public struct Recognized: Equatable, Sendable {
    public var name: String
    public var entry: GameEntry?

    public init(name: String, entry: GameEntry?) { self.name = name; self.entry = entry }
}

/// Which game a dropped folder is (spec D2, D3), matched on the Mac like every program.
public enum Recognize {
    /// The first candidate the games list (then the games learned from Steam) knows, named as the list names it;
    /// else the first non-empty candidate, with no entry.
    public static func game(candidates: [String], index: GameIndex, learned: GameIndex?) -> Recognized {
        let names = candidates.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for name in names {
            if let entry = index.match(name: name, exe: nil) ?? learned?.match(name: name, exe: nil) {
                return Recognized(name: entry.name, entry: entry)
            }
        }
        return Recognized(name: names.first ?? "", entry: nil)
    }

    /// Only the firm no waits for Install Anyway: anti-cheat with no single-player (D3).
    public static func needsConfirmation(_ entry: GameEntry?) -> Bool {
        entry.map { Verdicts.play($0).kind == .antiCheatBlocked } ?? false
    }

    /// The Library tile this game already is: the same games-list entry, else the same normalized name.
    public static func existing(_ game: Recognized, in library: [LibraryGame]) -> LibraryGame? {
        let tiles = library.filter { !$0.isSteamClient }
        if let id = game.entry?.id, let tile = tiles.first(where: { $0.entry?.id == id }) { return tile }
        let name = GameName.normalized(game.name)
        return tiles.first { GameName.normalized($0.name) == name }
    }
}
