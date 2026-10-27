import CryptoKit
import Foundation

/// Wine's .update-timestamp: a prefix holds the mtime of the wine.inf it was last set up with, and
/// Wine redoes the setup on launch when that differs from the current wine.inf's mtime.
public enum SetupStamp {
    public static func mtime(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) }
    }

    public static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func read(_ bottle: Bottle) -> Int? {
        (try? String(contentsOf: bottle.url.appendingPathComponent(".update-timestamp"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func write(_ bottle: Bottle, _ value: Int) throws {
        try "\(value)\n".write(to: bottle.url.appendingPathComponent(".update-timestamp"), atomically: true, encoding: .utf8)
    }

    /// Keeps the stamp current when only wine.inf's date changed, and records the wine.inf the prefix
    /// is set up with. Returns the config, updated if needed.
    public static func reconcile(_ bottle: Bottle, _ config: BottleConfig, runtime: Runtime) throws -> BottleConfig {
        guard let mtime = mtime(of: runtime.wineInf), let hash = sha256(of: runtime.wineInf) else { return config }
        var config = config
        let stamp = read(bottle)
        if stamp == mtime {
            if config.setupInf != hash { config.setupInf = hash; try bottle.save(config) }
        } else if config.setupInf == hash {
            try write(bottle, mtime)
            Launcher.appendLog(bottle, "wine.inf is unchanged (only its date differs); skipping Wine's setup redo")
        }
        return config
    }
}
