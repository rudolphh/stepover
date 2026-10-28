import Foundation

/// What the Wine Runtimes window shows and does: which runtimes to keep, which bottles use one, removing one.
public enum RuntimeCatalog {
    /// The two newest runtimes that aren't pulled (spec 5); the rest get a Remove button.
    public static func kept(installed: [String], pulled: Set<String>) -> Set<String> {
        Set(installed.filter { !pulled.contains($0) }.suffix(2))
    }

    /// Bottles pinned to a runtime or currently running on it, by name.
    public static func users(of runtime: String, bottles: [(name: String, pinned: String?, resolved: String?)]) -> [String] {
        bottles.filter { $0.pinned == runtime || $0.resolved == runtime }.map(\.name).sorted()
    }

    /// Deletes a runtime, unless a bottle that uses it is running. Bottles pinned to it fall back to the
    /// newest good runtime (Runtime.choose); the app asks before calling this when any bottle uses it.
    public static func remove(_ runtime: Runtime, bottles: [Bottle],
                              resolved: (Bottle) -> String? = { $0.runtime($0.loadConfig())?.name }) throws {
        if let busy = bottles.first(where: { resolved($0) == runtime.name && $0.isRunning }) {
            throw StepoverError.message("\(busy.name) is running on \(runtime.name); quit it first")
        }
        try FileManager.default.removeItem(at: runtime.url)
    }
}
