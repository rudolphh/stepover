import Foundation
import GamesListBuilder

// games-list build --fixes <dir> --out <file> [--previous <file>]   builds games.json (the Games list workflow)
// games-list verify <file>                                           checks a file decodes as the app reads it
// Env: STEPOVER_GAMES_STEAM_BUDGET (Steam requests per run, default 1200), STEPOVER_GAMES_STEAM_DELAY (seconds, 1.5).

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func option(_ name: String, in args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

switch args.first {
case "verify":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]), let list = GamesList.decode(data) else {
        fail("not a games list")
    }
    print("ok: \(list.games.count) games")

case "build":
    guard let fixesDir = option("--fixes", in: args), let out = option("--out", in: args) else {
        fail("usage: games-list build --fixes <dir> --out <file> [--previous <file>]", code: 2)
    }
    let previous = option("--previous", in: args).flatMap { FileManager.default.contents(atPath: $0) }.flatMap(GamesList.decode)
    let budget = env["STEPOVER_GAMES_STEAM_BUDGET"].flatMap { Int($0) } ?? 1200
    let delay = env["STEPOVER_GAMES_STEAM_DELAY"].flatMap { Double($0) } ?? 1.5
    let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))

    var fixes: [Fix] = []
    for folder in ["games", "proton"] {
        let dir = URL(fileURLWithPath: fixesDir).appendingPathComponent(folder)
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(file).path),
                  let fix = try? JSONDecoder().decode(Fix.self, from: data) else {
                print("skipping \(folder)/\(file): not a fix")
                continue
            }
            fixes.append(fix)
        }
    }

    func attempt<T>(_ source: String, _ fetch: () async throws -> T) async -> T? {
        do { return try await fetch() } catch {
            print("\(source) failed: \(error); keeping the previous data")
            return nil
        }
    }
    let agw = await attempt("AppleGamingWiki") { try await Fetch.appleGamingWiki() }
    let antiCheat = await attempt("AreWeAntiCheatYet") { try await Fetch.antiCheat() }
    let charts = await attempt("Steam charts") { try await Fetch.mostPlayed() }
    print("sources: \(agw.map { "\($0.count)" } ?? "no") AppleGamingWiki pages, \(antiCheat.map { "\($0.count)" } ?? "no") anti-cheat games, "
          + "\(charts.map { "\($0.count)" } ?? "no") charted, \(fixes.count) fixes; previous list \(previous?.games.count ?? 0) games")

    var games = Merge.entries(BuildSources(agw: agw, antiCheat: antiCheat, fixes: fixes, mostPlayed: charts), previous: previous)
    // a quarter of the Steam budget finds app ids for wiki pages that don't record one; the rest refreshes facts
    let searches = Merge.steamToSearch(games, today: today, limit: budget / 4)
    let spent = await Fetch.resolveSteamIDs(searches, in: &games, today: today, budget: budget / 4, delay: delay)
    let due = Merge.steamToRefresh(games, today: today, limit: (budget - spent) / 2)
    let refreshed = await Fetch.steam(due, into: &games, today: today, budget: budget - spent, delay: delay)
    games = Merge.publishable(games)

    let list = GamesList(format: GamesList.supportedFormat, generated: ISO8601DateFormatter().string(from: Date()), credits: [
        "Mac test results from AppleGamingWiki (applegamingwiki.com), CC BY-NC-SA 3.0.",
        "Anti-cheat data from AreWeAntiCheatYet (areweanticheatyet.com), MIT License.",
    ], games: games)
    do { try Merge.check(list, previous: previous) } catch { fail("\(error)") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do { try encoder.encode(list).write(to: URL(fileURLWithPath: out), options: .atomic) } catch { fail("can't write \(out): \(error)") }
    print("wrote \(out): \(games.count) games, \(games.filter { $0.store != nil }.count) with Steam facts (\(refreshed) refreshed this run)")

default:
    fail("usage: games-list build --fixes <dir> --out <file> [--previous <file>] | verify <file>", code: 2)
}
