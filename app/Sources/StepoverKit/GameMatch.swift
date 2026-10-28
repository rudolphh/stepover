import Foundation

/// Game names reduced to what they have in common across stores and wikis, for matching on the Mac.
public enum GameName {
    /// Longest first, so "goty edition" goes before "goty".
    static let editions = ["game of the year edition", "goty edition", "goty", "definitive edition", "complete edition",
                           "ultimate edition", "deluxe edition", "enhanced edition", "anniversary edition"]

    /// Case and accents folded, ™ ® © dropped, "&" read as "and", every run of other characters one space,
    /// and one trailing edition phrase dropped: "The Witcher 3: Wild Hunt – Game of the Year Edition" is
    /// "the witcher 3 wild hunt". Nothing fuzzier: a wrong match is worse than none.
    public static func normalized(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        for mark in ["™", "®", "©"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacingOccurrences(of: "&", with: " and ")
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? $0 : " "
        }))
        let words = spaced.split(separator: " ").joined(separator: " ")
        for edition in editions where words.hasSuffix(" " + edition) {
            return String(words.dropLast(edition.count + 1))
        }
        return words
    }
}

/// Lookups into the games list: by Steam app id, by exe file name, by name.
public struct GameIndex: Sendable {
    private let bySteam: [Int: GameEntry]
    private let byExe: [String: [GameEntry]]
    private let byName: [String: [GameEntry]]

    public init(_ list: GamesList) {
        var steam: [Int: GameEntry] = [:], exe: [String: [GameEntry]] = [:], name: [String: [GameEntry]] = [:]
        for game in list.games {
            if let id = game.steam, steam[id] == nil { steam[id] = game }
            for file in Set(game.exes.map { $0.lowercased() }) { exe[file, default: []].append(game) }
            for key in Set(([game.name] + game.names).map(GameName.normalized)) where !key.isEmpty {
                name[key, default: []].append(game)
            }
        }
        bySteam = steam; byExe = exe; byName = name
    }

    public func entry(steam appID: Int) -> GameEntry? { bySteam[appID] }

    /// The one entry whose exe names include `exe` (file name, any case), else the one entry whose name or
    /// other names normalize to `name`'s; nil when none or more than one fits.
    public func match(name: String, exe: String?) -> GameEntry? {
        if let exe, let game = Self.single(byExe[exe.lowercased()]) { return game }
        return Self.single(byName[GameName.normalized(name)])
    }

    private static func single(_ games: [GameEntry]?) -> GameEntry? {
        guard let games, Set(games.map(\.id)).count == 1 else { return nil }
        return games.first
    }
}
