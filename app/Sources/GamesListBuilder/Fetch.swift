import Foundation

/// The builder's network side: AppleGamingWiki's API, AreWeAntiCheatYet's games.json, Steam's charts,
/// store and Steam Deck answers. Every request carries a User-Agent naming Stepover, and each source is
/// paced so a daily run stays polite.
public enum Fetch {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    static var userAgent: String {
        let repository = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"].flatMap { $0.isEmpty ? nil : $0 } ?? "rudolphh/stepover"
        return "Stepover games list (https://github.com/\(repository))"
    }

    /// The body and HTTP status of a GET.
    static func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func getOK(_ url: URL) async throws -> Data {
        let (data, status) = try await get(url)
        guard (200..<300).contains(status) else { throw Failure(description: "HTTP \(status) from \(url.host ?? "")") }
        return data
    }

    static func pause(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    static func wikiAPI(_ items: [String: String]) -> URL {
        var parts = URLComponents(string: "https://www.applegamingwiki.com/w/api.php")!
        parts.queryItems = (items.merging(["format": "json", "formatversion": "2"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    /// Every page that uses Template:Compatibility/macOS, read 50 at a time, one request a second.
    public static func appleGamingWiki() async throws -> [AGWPage] {
        var titles: [String] = [], next: String?
        repeat {
            var query = ["action": "query", "list": "embeddedin", "eititle": "Template:Compatibility/macOS",
                         "einamespace": "0", "eilimit": "500"]
            if let next { query["eicontinue"] = next }
            let body = try JSONSerialization.jsonObject(with: try await getOK(wikiAPI(query))) as? [String: Any]
            titles += ((body?["query"] as? [String: Any])?["embeddedin"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            next = (body?["continue"] as? [String: Any])?["eicontinue"] as? String
            await pause(1)
        } while next != nil
        guard !titles.isEmpty else { throw Failure(description: "no pages use Template:Compatibility/macOS") }

        var pages: [AGWPage] = []
        for start in stride(from: 0, to: titles.count, by: 50) {
            let batch = titles[start..<min(start + 50, titles.count)]
            let url = wikiAPI(["action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                               "titles": batch.joined(separator: "|")])
            let body = try JSONSerialization.jsonObject(with: try await getOK(url)) as? [String: Any]
            for page in (body?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [] {
                guard let title = page["title"] as? String,
                      let revision = (page["revisions"] as? [[String: Any]])?.first,
                      let text = ((revision["slots"] as? [String: Any])?["main"] as? [String: Any])?["content"] as? String,
                      let parsed = AppleGamingWiki.parse(title: title, wikitext: text) else { continue }
                pages.append(parsed)
            }
            await pause(1)
        }
        return pages
    }

    public static func antiCheat() async throws -> [AntiCheatGame] {
        let url = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json")!
        guard let games = AntiCheatList.decode(try await getOK(url)), !games.isEmpty else {
            throw Failure(description: "AreWeAntiCheatYet's games.json didn't decode")
        }
        return games
    }

    /// Steam's most played games right now (no key needed).
    public static func mostPlayed() async throws -> [Int] {
        let url = URL(string: "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/")!
        let body = try JSONSerialization.jsonObject(with: try await getOK(url)) as? [String: Any]
        let ranks = (body?["response"] as? [String: Any])?["ranks"] as? [[String: Any]] ?? []
        guard !ranks.isEmpty else { throw Failure(description: "Steam's charts were empty") }
        return ranks.compactMap { $0["appid"] as? Int }
    }

    /// Looks up wiki-only games (entry ids) by name on Steam's store search, one request each, and moves the
    /// ones with exactly one same-named result to their Steam app id (Merge.resolve). The others are marked
    /// searched today. Stops on 429 or 403 or when `budget` is spent; returns the requests spent.
    public static func resolveSteamIDs(_ ids: [String], in entries: inout [GameEntry], today: String, budget: Int,
                                       delay: TimeInterval) async -> Int {
        var spent = 0
        for id in ids {
            guard spent < budget, let game = entries.first(where: { $0.id == id }) else { break }
            do {
                let (body, status) = try await get(SteamStore.searchURL(game.name))
                spent += 1
                if status == 429 || status == 403 { print("Steam answered \(status); stopping Steam lookups for this run"); break }
                if let results = SteamStore.searchResults(body) {
                    if let steam = Merge.pickSteamID(results, for: game.name) {
                        entries = Merge.resolve(entries, id: id, steam: steam)
                    } else if let i = entries.firstIndex(where: { $0.id == id }) {
                        entries[i].steamSearched = today
                    }
                }
            } catch {
                print("Steam search for \(game.name) failed: \(error.localizedDescription)")
            }
            await pause(delay)
        }
        return spent
    }

    /// Fills Steam store and Deck facts for `ids` (two requests each), waiting `delay` between requests. Stops
    /// early, keeping what it has, when Steam answers 429 or 403 or `budget` requests are spent. Returns how
    /// many games it refreshed.
    @discardableResult
    public static func steam(_ ids: [Int], into entries: inout [GameEntry], today: String, budget: Int,
                             delay: TimeInterval) async -> Int {
        var spent = 0, refreshed = 0
        let index = Dictionary(entries.indices.compactMap { i in entries[i].steam.map { ($0, i) } }) { a, _ in a }
        for id in ids {
            guard spent + 2 <= budget else { break }
            guard let i = index[id] else { continue }
            do {
                let (details, status) = try await get(SteamStore.appdetailsURL(id))
                spent += 1
                if status == 429 || status == 403 { print("Steam answered \(status); stopping Steam lookups for this run"); break }
                if let (name, facts) = SteamStore.storeFacts(appdetails: details, appID: id, checked: today) {
                    if entries[i].name != name, !entries[i].name.isEmpty { entries[i].names.append(entries[i].name) }
                    entries[i].name = name
                    entries[i].store = facts
                }
                await pause(delay)
                let (report, deckStatus) = try await get(SteamStore.deckReportURL(id))
                spent += 1
                if deckStatus == 429 || deckStatus == 403 { print("Steam answered \(deckStatus); stopping Steam lookups for this run"); break }
                if let deck = SteamStore.deckFacts(report: report, checked: today) { entries[i].deck = deck }
                refreshed += 1
                await pause(delay)
            } catch {
                print("Steam lookup for \(id) failed: \(error.localizedDescription)")
                await pause(delay)
            }
        }
        return refreshed
    }
}
