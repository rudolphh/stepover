import CryptoKit
import Foundation

/// A list of fixes Stepover downloads: "github:owner/repo" (its fixes/ folder, optionally
/// "@branch") or an https link to a JSON file holding fixes.
public struct FixSource: Codable, Hashable, Sendable {
    public var name: String
    public var url: String
    /// Apply flagged items too (see fixes/README.md, Safety). Your own local fixes always are.
    public var trusted: Bool
    public init(name: String, url: String, trusted: Bool = false) { self.name = name; self.url = url; self.trusted = trusted }
}

/// Where fixes come from, in the order they apply (later ones win where they overlap):
/// the official list (downloaded, else the copy inside Stepover.app), sources you added, and your own
/// fixes in <Fixes>/Local.
public enum FixLibrary {
    public static var localFolder: URL { Paths.fixes.appendingPathComponent("Local") }
    static var cacheFolder: URL { Paths.fixes.appendingPathComponent("Sources") }
    static var sourcesFile: URL { Paths.fixes.appendingPathComponent("sources.json") }

    /// STEPOVER_FIXES_SOURCE, else the repository Stepover.app was built from, else rudolphh/stepover.
    public static var official: FixSource {
        if let env = ProcessInfo.processInfo.environment["STEPOVER_FIXES_SOURCE"], !env.isEmpty {
            return FixSource(name: "official", url: env)
        }
        return FixSource(name: "official", url: "github:\(Paths.sourceRepository)")
    }

    public static func addedSources() -> [FixSource] {
        guard let data = try? Data(contentsOf: sourcesFile) else { return [] }
        return (try? JSONDecoder().decode([FixSource].self, from: data)) ?? []
    }

    public static func setAddedSources(_ sources: [FixSource]) throws {
        try FileManager.default.createDirectory(at: Paths.fixes, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources.filter { $0.name != official.name }).write(to: sourcesFile)
    }

    public struct Loaded: Sendable {
        public var fixes: [Fix] = []
        /// Fixes skipped as invalid, and flagged items left out, with where they came from.
        public var notes: [String] = []
    }

    /// Every usable fix. Invalid fixes are skipped; flagged items are left out unless the source is
    /// trusted or the fix is your own.
    public static func load() -> Loaded {
        var loaded = Loaded()
        let officialCache = cacheFolder.appendingPathComponent(official.name)
        let officialFolder = FileManager.default.fileExists(atPath: officialCache.path)
            ? officialCache : Paths.appBundle?.resourceURL?.appendingPathComponent("fixes")
        if let officialFolder { read(officialFolder, label: official.name, trusted: official.trusted, into: &loaded) }
        for source in addedSources() {
            read(cacheFolder.appendingPathComponent(safeName(source.name)), label: source.name, trusted: source.trusted, into: &loaded)
        }
        read(localFolder, label: "local", trusted: true, into: &loaded)
        return loaded
    }

    static func read(_ folder: URL, label: String, trusted: Bool, into loaded: inout Loaded) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        // converted fixes (proton/) load first, so a hand-written fix for the same game wins
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { a, b in
                let pa = a.path.contains("/proton/"), pb = b.path.contains("/proton/")
                return pa != pb ? pa : a.path < b.path
            }
        for file in files {
            let relative = String(file.path.dropFirst(folder.path.count + 1))
            guard let data = try? Data(contentsOf: file), let fixes = try? Fix.decodeFile(data) else {
                loaded.notes.append("\(label)/\(relative): not a fix file (invalid JSON)")
                continue
            }
            for (i, var fix) in fixes.enumerated() {
                fix.id = fixes.count == 1 ? "\(label)/\(relative)" : "\(label)/\(relative)#\(i + 1)"
                let problems = fix.problems()
                if !problems.isEmpty {
                    loaded.notes += problems.map { "\(fix.id): \($0)" }
                    continue
                }
                if !trusted {
                    loaded.notes += fix.flagged().map { "\(fix.id): left out \($0)" }
                    fix = fix.withoutFlagged()
                }
                loaded.fixes.append(fix)
            }
        }
    }

    // MARK: downloading

    /// Downloads every source into <Fixes>/Sources; returns one line per source.
    public static func update() async -> [String] {
        var report: [String] = []
        for source in [official] + addedSources() {
            do {
                let count = try await download(source)
                report.append("\(source.name): \(count) fix files")
            } catch {
                report.append("\(source.name): \(error.localizedDescription)")
            }
        }
        return report
    }

    static func download(_ source: FixSource) async throws -> Int {
        let fm = FileManager.default
        let dest = cacheFolder.appendingPathComponent(safeName(source.name))
        let staging = cacheFolder.appendingPathComponent(".new-\(safeName(source.name))")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        if source.url.hasPrefix("github:") {
            let spec = source.url.dropFirst("github:".count).split(separator: "@", maxSplits: 1).map(String.init)
            let ref = spec.count > 1 ? "/\(spec[1])" : ""
            guard spec[0].split(separator: "/").count == 2,
                  let url = URL(string: "https://api.github.com/repos/\(spec[0])/tarball\(ref)") else {
                throw StepoverError.message("\(source.url) should look like github:owner/repo")
            }
            let archive = staging.appendingPathComponent("repo.tar.gz")
            try await fetch(url, to: archive)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", staging.path, "--include", "*/fixes/*"]
            try tar.run(); tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw StepoverError.message("unpacking \(source.url) failed (tar exit \(tar.terminationStatus))") }
            let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .first { fm.fileExists(atPath: $0.appendingPathComponent("fixes").path) }
            guard let fixes = top?.appendingPathComponent("fixes") else {
                throw StepoverError.message("\(source.url) has no fixes folder")
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: fixes, to: dest)
        } else if let url = URL(string: source.url), url.scheme == "https" {
            let file = staging.appendingPathComponent("fixes.json")
            try await fetch(url, to: file)
            _ = try Fix.decodeFile(Data(contentsOf: file))  // reject anything that isn't a fix file
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: dest.appendingPathComponent("fixes.json"))
        } else {
            throw StepoverError.message("\(source.url) isn't github:owner/repo or an https link")
        }
        let walker = fm.enumerator(at: dest, includingPropertiesForKeys: nil)
        return walker?.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.count ?? 0
    }

    static func fetch(_ url: URL, to file: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("Stepover", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StepoverError.message("HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
    }

    // MARK: your own fixes and sharing them

    /// A program's current settings as a fix: what to save or share once a game works.
    public static func fix(from program: Program, in bottle: Bottle) -> Fix {
        let config = bottle.loadConfig()
        var fix = Fix(name: program.name, match: .init(exe: [program.exeName]))
        if let exe = WindowsPath.toMac(program.exe, bottle: bottle.url)?.standardizedFileURL.path,
           let app = SteamLibrary.apps(in: bottle).first(where: { exe.hasPrefix($0.folder.standardizedFileURL.path + "/") }) {
            fix.match.steam = [app.id]
        }
        fix.graphics = config.backend(for: program).rawValue
        // only this program's own settings: the bottle's variables and its installed components can
        // hold personal paths or belong to other games, and shared fixes are public
        fix.env = program.env
        fix.args = program.args
        fix.notes = config.msync ? "Works with MSync on." : "Works with MSync off."
        fix.source = "Saved from Stepover"
        return fix
    }

    /// Writes a fix into <Fixes>/Local (your own fixes, applied as written); returns the file.
    @discardableResult
    public static func saveLocal(_ fix: Fix) throws -> URL {
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let file = localFolder.appendingPathComponent("\(slug(fix.name)).json")
        try fix.json().write(to: file)
        return file
    }

    /// GitHub's "new file" page in the official repository with the fix filled in; GitHub offers
    /// to fork and open a pull request.
    public static func shareURL(for fix: Fix) -> URL? {
        guard let repo = officialRepo, let json = try? String(data: fix.json(), encoding: .utf8) else { return nil }
        var parts = URLComponents(string: "https://github.com/\(repo)/new/main/fixes/games")
        parts?.queryItems = [URLQueryItem(name: "filename", value: "\(slug(fix.name)).json"), URLQueryItem(name: "value", value: json)]
        return parts?.url
    }

    /// A new GitHub issue in the official repository, filled in with how a game ran.
    public static func reportURL(program: Program, in bottle: Bottle) -> URL? {
        guard let repo = officialRepo else { return nil }
        let config = bottle.loadConfig()
        let runtime = bottle.runtime(config)
        let applied = Launcher.matchedFixes(bottle, config: config).map { "- \($0.fix.name) (\($0.fix.id))" }
        let body = """
        **Game:** \(program.name) (`\(program.exeName)`)
        **How it ran:** <!-- works / works with problems / doesn't start; fps if you know it -->

        **Stepover:** \(Paths.appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev build")
        **Runtime:** \(runtime?.summary ?? "none")
        **Graphics:** \(config.backend(for: program).label), MSync \(config.msync ? "on" : "off")
        **macOS:** \(ProcessInfo.processInfo.operatingSystemVersionString)
        **Fixes applied:**
        \(applied.isEmpty ? "none" : applied.joined(separator: "\n"))
        """
        var parts = URLComponents(string: "https://github.com/\(repo)/issues/new")
        parts?.queryItems = [URLQueryItem(name: "title", value: "\(program.name): "), URLQueryItem(name: "body", value: body)]
        return parts?.url
    }

    /// How to write and share fixes (fixes/README.md in the official repository).
    public static var guideURL: URL? {
        officialRepo.flatMap { URL(string: "https://github.com/\($0)/blob/main/fixes/README.md") }
    }

    static var officialRepo: String? {
        official.url.hasPrefix("github:") ? String(official.url.dropFirst("github:".count).split(separator: "@")[0]) : nil
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return s.split(separator: "-").joined(separator: "-")
    }

    /// A cache folder name for a source: readable, plus a hash of the exact name so two sources
    /// never share a folder.
    static func safeName(_ name: String) -> String {
        let readable = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let hash = SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return name == official.name ? name : "\(readable)-\(hash)"
    }
}
