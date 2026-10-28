import Foundation

extension WindowsPath {
    public static func toMac(_ path: String, bottle: Bottle) -> URL? { toMac(path, bottle: bottle.url) }
    public static func toWindows(_ url: URL, bottle: Bottle) -> String { toWindows(url, bottle: bottle.url) }
}

public enum StepoverError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// A Wine prefix in Paths.bottles with its stepover.json.
public struct Bottle: Hashable, Identifiable, Sendable {
    public let url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var configURL: URL { url.appendingPathComponent("stepover.json") }
    public var compatURL: URL { url.appendingPathComponent("stepover-compat.conf") }
    public var logURL: URL { Paths.logs.appendingPathComponent("\(name).log") }
    public var cDrive: URL { url.appendingPathComponent("drive_c") }

    public init(url: URL) { self.url = url }

    public static func all() -> [Bottle] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Paths.bottles.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { Bottle(url: Paths.bottles.appendingPathComponent($0)) }
            .filter { fm.fileExists(atPath: $0.url.appendingPathComponent("system.reg").path) || fm.fileExists(atPath: $0.configURL.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func named(_ name: String) -> Bottle? {
        all().first { $0.name == name } ?? all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func loadConfig() -> BottleConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(BottleConfig.self, from: data) else { return BottleConfig() }
        return config
    }

    /// Writes stepover.json and the stepover-compat.conf the compat plug-in reads, with the matched
    /// fixes (so saving a setting while a game runs doesn't drop them). Pass `fixes` when already
    /// known; otherwise this reads the fix list and scans the bottle.
    public func save(_ config: BottleConfig, fixes: [MatchedFix]? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        let matched = fixes ?? Launcher.matchedFixes(self, config: config)
        try config.compatConf(fixes: matched).write(to: compatURL, atomically: true, encoding: .utf8)
    }

    public func runtime(_ config: BottleConfig) -> Runtime? { Runtime.resolve(pinned: config.runtime, lastUsed: lastRuntime) }

    /// The runtime this bottle last ran on (Launcher.session records it). Kept beside stepover.json, not in
    /// it: the app and the stepover command both write stepover.json, and the app's in-memory copy would
    /// overwrite a value the command wrote.
    public var lastRuntime: String? {
        get {
            (try? String(contentsOf: lastRuntimeFile, encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        nonmutating set {
            if let newValue { try? (newValue + "\n").write(to: lastRuntimeFile, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: lastRuntimeFile) }
        }
    }

    var lastRuntimeFile: URL { url.appendingPathComponent(".stepover-last-runtime") }

    /// True while the bottle's wineserver holds the lock in its server directory
    /// (/tmp/.wine-<uid>/server-<dev>-<inode>/lock), whichever Wine started it.
    public var isRunning: Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        let lock = "/tmp/.wine-\(getuid())/server-\(String(UInt32(bitPattern: st.st_dev), radix: 16))-\(String(st.st_ino, radix: 16))/lock"
        let fd = open(lock, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &fl) == 0 else { return false }
        return fl.l_type != Int16(F_UNLCK)
    }

    // MARK: registry-backed display settings

    public var userRegistry: RegistryFile { RegistryFile(url: url.appendingPathComponent("user.reg")) }

    /// Wine's Mac driver "High Resolution Mode" (RetinaMode=y): full Retina pixels instead of points.
    public var highResolution: Bool {
        userRegistry.string(#"Software\Wine\Mac Driver"#, "RetinaMode")?.lowercased().hasPrefix("y") ?? false
    }

    /// Windows DPI (LogPixels); 96 = 100%.
    public var dpi: Int {
        Int(userRegistry.dword(#"Control Panel\Desktop"#, "LogPixels") ?? 96)
    }
}
