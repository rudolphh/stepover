import Foundation

/// What one run of the builder fetched. A nil source failed this run: its data comes from the previous list.
public struct BuildSources: Sendable {
    public var agw: [AGWPage]?
    public var antiCheat: [AntiCheatGame]?
    public var fixes: [Fix]
    public var mostPlayed: [Int]?          // Steam app ids

    public init(agw: [AGWPage]?, antiCheat: [AntiCheatGame]?, fixes: [Fix], mostPlayed: [Int]?) {
        self.agw = agw; self.antiCheat = antiCheat; self.fixes = fixes; self.mostPlayed = mostPlayed
    }
}

public struct ListCheckFailure: Error, CustomStringConvertible {
    public let description: String
}

public enum Merge {
    public static let minimumFirstList = 500

    /// One entry per game: the Steam app id when any source knows it, else the AppleGamingWiki title, else the
    /// AreWeAntiCheatYet slug. Fields from a source that worked this run are rebuilt from it; a failed source's
    /// fields, and Steam and Deck facts, come from `previous`. Games nothing knows about any more are dropped.
    public static func entries(_ sources: BuildSources, previous: GamesList?) -> [GameEntry] {
        var games: [String: GameEntry] = [:]
        var found: [String: [String]] = [:]    // names the sources gave each game, in precedence order
        for var game in previous?.games ?? [] {
            if sources.agw != nil { game.agwPage = nil; game.mac = nil }
            if sources.antiCheat != nil { game.antiCheat = nil }
            game.exes = []; game.fix = false    // the fix list is local, so it is always rebuilt
            games[game.id] = game
        }
        func edit(_ id: String, steam: Int?, _ change: (inout GameEntry) -> Void) {
            var game = games[id] ?? GameEntry(id: id, name: "", steam: steam)
            change(&game)
            games[id] = game
        }

        // An app id two wiki pages claim (a typo on the wiki) stays only with the page named like the Steam game,
        // once Steam has named it; the other pages become wiki-only, which the name search can then place.
        let collisions = idCollisions(sources.agw ?? [])
        let previousByID = Dictionary((previous?.games ?? []).map { ($0.id, $0) }) { a, _ in a }
        // Steam ids found earlier for pages that don't record one (resolve), never a contested id
        let resolved = Dictionary((previous?.games ?? []).compactMap { game in
            game.agwPage.flatMap { page in game.steam.flatMap { collisions[$0] == nil ? (page, $0) : nil } }
        }) { a, _ in a }
        for page in sources.agw ?? [] {
            var steam = page.steam
            if let claimed = steam, collisions[claimed] != nil {
                let steamName = previousByID["steam:\(claimed)"].flatMap { $0.store != nil ? $0.name : nil }
                if steamName.map({ GameName.normalized($0, dropEdition: false) == GameName.normalized(page.title, dropEdition: false) }) != true {
                    steam = nil
                }
            }
            steam = steam ?? resolved[page.title]
            let id = steam.map { "steam:\($0)" } ?? "agw:\(page.title)"
            let tests = page.tests
            edit(id, steam: steam) {
                $0.agwPage = page.title
                $0.mac = (tests.native ?? tests.rosetta ?? tests.crossover ?? tests.wine) == nil ? nil : tests
            }
            found[id, default: []].append(page.title)
        }
        // the one game so far whose names match, for sources that don't know a store id; `except` is the
        // source's own fallback identity, which the previous list may hold for the same game
        func sameNamed(_ name: String, except: String? = nil) -> String? {
            let key = GameName.normalized(name)
            let same = games.values.filter { game in
                game.id != except && ([game.name] + game.names + (found[game.id] ?? [])).contains { GameName.normalized($0) == key }
            }
            return same.count == 1 ? same[0].id : nil
        }
        for game in sources.antiCheat ?? [] {
            let id = game.steam.map { "steam:\($0)" } ?? sameNamed(game.name, except: "acy:\(game.slug)") ?? "acy:\(game.slug)"
            edit(id, steam: game.steam) {
                $0.antiCheat = AntiCheat(names: game.anticheats, status: game.status)
                $0.epic = game.epic ?? $0.epic
            }
            found[id, default: []].append(game.name)
        }
        for fix in sources.fixes {
            var ids = fix.match.steam.map { "steam:\($0)" }
            if ids.isEmpty, let same = sameNamed(fix.name) { ids = [same] }   // no store id: the one game of that name
            for id in ids {
                edit(id, steam: Int(id.dropFirst("steam:".count))) {
                    for exe in fix.match.exe where !$0.exes.contains(where: { $0.caseInsensitiveCompare(exe) == .orderedSame }) {
                        $0.exes.append(exe)
                    }
                    $0.fix = true
                }
                found[id, default: []].append(fix.name)
            }
        }
        let charted = Set(sources.mostPlayed ?? [])
        for id in charted { edit("steam:\(id)", steam: id) { _ in } }

        return games.values.compactMap { game -> GameEntry? in
            var game = game
            let known = game.agwPage != nil || game.antiCheat != nil || game.fix || game.store != nil || game.deck != nil
                || game.steam.map(charted.contains) == true
            guard known else { return nil }
            // a Steam name (from store facts) wins, then the sources' names, then what the game was called before;
            // other names come from this run's sources, and from the previous list only when a source failed
            let sourced = found[game.id] ?? []
            let carried = sources.agw == nil || sources.antiCheat == nil ? [game.name] + game.names : []
            game.name = ((game.store != nil ? [game.name] : []) + sourced + [game.name]).first { !$0.isEmpty } ?? ""
            var seen: Set<String> = [GameName.normalized(game.name)]
            game.names = (sourced + carried).filter { !$0.isEmpty && seen.insert(GameName.normalized($0)).inserted }
            return game
        }.sorted { $0.id < $1.id }
    }

    /// Wiki-only games (no Steam app id yet) to look up by name on Steam: never searched first, then those
    /// last searched more than `maxAge` days ago.
    public static func steamToSearch(_ entries: [GameEntry], today: String, maxAge: Int = 30, limit: Int) -> [String] {
        // a title another wiki page shares once "(2017)"-style years are dropped ("Star Wars: Battlefront II" and
        // "Star Wars Battlefront II (2017)") names two games; the search can't tell which Steam game is which
        func base(_ title: String) -> String {
            GameName.normalized(title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression), dropEdition: false)
        }
        let shared = Set(Dictionary(grouping: entries.compactMap(\.agwPage), by: base).filter { $0.value.count > 1 }.keys)
        let due = entries.filter { $0.steam == nil && $0.agwPage != nil && !shared.contains(base($0.agwPage!)) }
            .filter { game in game.steamSearched.map { days(from: $0, to: today) > maxAge } ?? true }
        let never = due.filter { $0.steamSearched == nil }
        let stale = due.filter { $0.steamSearched != nil }.sorted { $0.steamSearched! < $1.steamSearched! }
        return (never + stale).prefix(limit).map(\.id)
    }

    /// The one search result whose name is the game's name (GameName.normalized, editions kept, so a
    /// "Definitive Edition" remake never stands in for the original); nil when none or several.
    public static func pickSteamID(_ results: [(id: Int, name: String)], for name: String) -> Int? {
        let key = GameName.normalized(name, dropEdition: false)
        let same = Set(results.filter { GameName.normalized($0.name, dropEdition: false) == key }.map(\.id))
        return same.count == 1 ? same.first : nil
    }

    /// Moves entry `id` to "steam:<steam>", merging it into that entry when one exists (the Steam entry's
    /// own facts win; the wiki's results, exes and names are added).
    public static func resolve(_ entries: [GameEntry], id: String, steam: Int) -> [GameEntry] {
        guard let moving = entries.first(where: { $0.id == id }) else { return entries }
        let target = "steam:\(steam)"
        var rest = entries.filter { $0.id != id }
        if let i = rest.firstIndex(where: { $0.id == target }) {
            var game = rest[i]
            game.agwPage = game.agwPage ?? moving.agwPage
            game.mac = game.mac ?? moving.mac
            game.antiCheat = game.antiCheat ?? moving.antiCheat
            game.epic = game.epic ?? moving.epic
            game.exes += moving.exes.filter { exe in !game.exes.contains { $0.caseInsensitiveCompare(exe) == .orderedSame } }
            game.fix = game.fix || moving.fix
            var seen = Set(([game.name] + game.names).map { GameName.normalized($0) })
            game.names += ([moving.name] + moving.names).filter { !$0.isEmpty && seen.insert(GameName.normalized($0)).inserted }
            rest[i] = game
        } else {
            var game = moving
            game.id = target; game.steam = steam; game.steamSearched = nil
            rest.append(game)
        }
        return rest.sorted { $0.id < $1.id }
    }

    /// The previous list. Nil only when there is none (`path` nil); a path that can't be read or isn't a games
    /// list throws, so a failed download never makes a run start over and drop every Steam fact.
    public static func loadPrevious(path: String?) throws -> GamesList? {
        guard let path else { return nil }
        guard let data = FileManager.default.contents(atPath: path), let list = GamesList.decode(data) else {
            throw ListCheckFailure(description: "the previous list (\(path)) isn't a readable games list; not building over it")
        }
        return list
    }

    /// Steam app ids that more than one wiki page claims, with those pages' titles (a typo on the wiki).
    public static func idCollisions(_ pages: [AGWPage]) -> [Int: [String]] {
        Dictionary(grouping: pages.filter { $0.steam != nil }, by: { $0.steam! })
            .filter { $0.value.count > 1 }.mapValues { $0.map(\.title) }
    }

    /// Steam app ids whose Steam facts are missing or older than `maxAge` days: never-checked first, then oldest.
    public static func steamToRefresh(_ entries: [GameEntry], today: String, maxAge: Int = 7, limit: Int) -> [Int] {
        let due = entries.compactMap { game -> (id: Int, last: String?)? in
            guard let id = game.steam else { return nil }
            guard let last = [game.store?.checked, game.deck?.checked].compactMap({ $0 }).max() else { return (id, nil) }
            return days(from: last, to: today) > maxAge ? (id, last) : nil
        }
        let never = due.filter { $0.last == nil }, stale = due.filter { $0.last != nil }.sorted { $0.last! < $1.last! }
        return (never + stale).prefix(limit).map(\.id)
    }

    /// Refuses a list that shrank by more than 10%, or a first list under minimumFirstList games: a source
    /// outage must never wipe what users have.
    public static func check(_ new: GamesList, previous: GamesList?) throws {
        if let previous, !previous.games.isEmpty {
            if Double(new.games.count) < Double(previous.games.count) * 0.9 {
                throw ListCheckFailure(description: "the list shrank from \(previous.games.count) to \(new.games.count) games; not publishing it")
            }
        } else if new.games.count < minimumFirstList {
            throw ListCheckFailure(description: "only \(new.games.count) games; a first list needs at least \(minimumFirstList)")
        }
    }

    /// Games with a name (a charted game Steam never named is left out), sorted by id so the file diffs cleanly.
    public static func publishable(_ entries: [GameEntry]) -> [GameEntry] {
        entries.filter { !$0.name.isEmpty }.sorted { $0.id < $1.id }
    }

    static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    static func days(from: String, to: String) -> Int {
        guard let a = day.date(from: from), let b = day.date(from: to) else { return .max }
        return Int(b.timeIntervalSince(a) / 86400)
    }
}
