import Foundation

/// Where Stepover keeps things. Every location can be overridden from the environment.
public enum Paths {
    static let env = ProcessInfo.processInfo.environment
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func url(_ variable: String, default fallback: URL) -> URL {
        if let value = env[variable], !value.isEmpty { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
        return fallback
    }

    /// STEPOVER_HOME, default ~/Library/Application Support/Stepover
    public static var root: URL {
        url("STEPOVER_HOME", default: home.appendingPathComponent("Library/Application Support/Stepover"))
    }
    /// STEPOVER_BOTTLES, default <root>/Bottles
    public static var bottles: URL { url("STEPOVER_BOTTLES", default: root.appendingPathComponent("Bottles")) }
    /// STEPOVER_RUNTIMES, default <root>/Runtimes
    public static var runtimes: URL { url("STEPOVER_RUNTIMES", default: root.appendingPathComponent("Runtimes")) }
    /// STEPOVER_LOGS, default ~/Library/Logs/Stepover
    public static var logs: URL { url("STEPOVER_LOGS", default: home.appendingPathComponent("Library/Logs/Stepover")) }
    /// STEPOVER_LAUNCHERS, default ~/Applications/Stepover (the per-game Mac apps)
    public static var launchers: URL { url("STEPOVER_LAUNCHERS", default: home.appendingPathComponent("Applications/Stepover")) }
    /// STEPOVER_CROSSOVER_BOTTLES, default ~/Library/Application Support/CrossOver/Bottles
    public static var crossOverBottles: URL {
        url("STEPOVER_CROSSOVER_BOTTLES", default: home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"))
    }
    /// STEPOVER_CROSSOVER_APP, default /Applications/CrossOver.app (only read, to compare its wine.inf on import)
    public static var crossOverApp: URL { url("STEPOVER_CROSSOVER_APP", default: URL(fileURLWithPath: "/Applications/CrossOver.app")) }
    /// STEPOVER_RUNTIME names the default runtime folder inside `runtimes`.
    public static var defaultRuntimeName: String? { env["STEPOVER_RUNTIME"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The `stepover` command the Mac launchers call: STEPOVER_CLI, else Stepover.app/Contents/MacOS/stepover-cli
    /// next to this executable (named -cli because "Stepover" and "stepover" collide on a case-insensitive disk).
    public static var cli: URL {
        if let value = env["STEPOVER_CLI"], !value.isEmpty { return URL(fileURLWithPath: value) }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = me.deletingLastPathComponent().appendingPathComponent("stepover-cli")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : me
    }
}
