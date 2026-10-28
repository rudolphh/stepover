import Foundation

public enum RuntimeStatus: String, Codable, Sendable {
    case current, available, pulled
}

/// Every published runtime: runtime/index.json on the main branch of the repository Stepover.app was built
/// from. Runtimes ship apart from the app, so this list (not the app) says what to download. The app keeps
/// the last copy it fetched in <root>/runtime-index.json and falls back to the runtime.json bundled in
/// Stepover.app when it has never reached GitHub.
public struct RuntimeIndex: Codable, Sendable {
    public var runtimes: [RuntimeManifest]

    public init(runtimes: [RuntimeManifest]) { self.runtimes = runtimes }

    /// The runtime new installs get: the last entry marked current (an entry with no status counts as current).
    public var current: RuntimeManifest? { runtimes.last { ($0.status ?? .current) == .current } }

    /// Runtimes the maintainer pulled.
    public var pulled: Set<String> { Set(runtimes.filter { $0.status == .pulled }.map(\.name)) }

    /// Nil for anything that isn't a runtime list. An entry is dropped when its name isn't a plain folder
    /// name (it becomes a folder under Runtimes) or its download isn't HTTPS; local files are allowed only
    /// when the list itself is a local file (STEPOVER_RUNTIME_INDEX), for tests and local builds.
    public static func decode(_ data: Data, allowLocal: Bool = false) -> RuntimeIndex? {
        guard var index = try? JSONDecoder().decode(RuntimeIndex.self, from: data) else { return nil }
        index.runtimes = index.runtimes.filter { entry in
            isFolderName(entry.name) && (entry.url.hasPrefix("https://") || (allowLocal && isLocal(entry.url)))
        }
        return index
    }

    public static var cacheFile: URL { Paths.root.appendingPathComponent("runtime-index.json") }

    /// STEPOVER_RUNTIME_INDEX (a URL or a file path), else runtime/index.json on the source repository's main.
    public static var source: String {
        if let value = Paths.env["STEPOVER_RUNTIME_INDEX"], !value.isEmpty { return value }
        return "https://raw.githubusercontent.com/\(Paths.sourceRepository)/main/runtime/index.json"
    }

    /// The cached list, else the runtime the app was built with.
    public static func load(cache: URL = cacheFile, bundled: RuntimeManifest? = RuntimeManifest.bundled()) -> RuntimeIndex {
        if let data = try? Data(contentsOf: cache), let index = decode(data, allowLocal: isLocal(source)),
           !index.runtimes.isEmpty {
            return index
        }
        return RuntimeIndex(runtimes: [bundled].compactMap { $0 })
    }

    /// Reads the list and replaces the cache only when what arrived is a list with at least one runtime.
    /// Offline, an error page or a broken file leave the cache as it was. Never throws.
    @discardableResult
    public static func fetch(from source: String = source, to cache: URL = cacheFile) async -> Bool {
        let data: Data
        if isLocal(source) {
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
        guard let index = decode(data, allowLocal: isLocal(source)), !index.runtimes.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cache, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func isLocal(_ location: String) -> Bool { !location.contains("://") || location.hasPrefix("file://") }

    static func isFolderName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil && !name.contains("..")
    }
}
