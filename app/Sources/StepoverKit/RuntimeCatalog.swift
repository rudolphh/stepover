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

    /// The runtime a bottle is using, for the Wine Runtimes window. A running bottle stays on the runtime its Wine
    /// started with (lastRuntime, written as Wine starts) even after its pin changes; otherwise the one it runs on now.
    public static func inUse(resolved: String?, running: Bool, lastRuntime: String?) -> String? {
        running ? (lastRuntime ?? resolved) : resolved
    }

    /// Why a runtime can't be removed right now (a bottle using it is running), or nil when it can.
    public static func refusal(_ runtime: String, bottles: [Bottle],
                               resolved: (Bottle) -> String? = { $0.runtime($0.loadConfig())?.name }) -> String? {
        bottles.first { $0.isRunning && ($0.lastRuntime == runtime || resolved($0) == runtime) }
            .map { "\($0.name) is running on \(runtime); quit it first" }
    }

    /// Deletes a runtime, unless a bottle that uses it is running. Bottles pinned to it fall back to the
    /// newest good runtime (Runtime.choose); the app asks before calling this when any bottle uses it.
    public static func remove(_ runtime: Runtime, bottles: [Bottle],
                              resolved: (Bottle) -> String? = { $0.runtime($0.loadConfig())?.name }) throws {
        if let reason = refusal(runtime.name, bottles: bottles, resolved: resolved) { throw StepoverError.message(reason) }
        try FileManager.default.removeItem(at: runtime.url)
    }

    /// "Sainthood", "A and B", "A, B and C".
    public static func joined(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// The confirmation before removing a runtime that bottles use.
    public static func removalMessage(users: [String], runtime: String, next: String?) -> String {
        "\(joined(users)) \(users.count == 1 ? "uses" : "use") \(runtime) and will switch to \(next ?? "no runtime")."
    }
}

/// What the bottle page says about the bottle's Wine version.
public enum BottleRuntimeState: Equatable {
    case newest(String)                                    // follows new runtimes
    case pinned(String, newer: String?)                    // a specific runtime; `newer` when a newer good one is installed
    case missingPin(String, using: String?)                // pinned to a runtime that isn't installed
    case onPulled(String, note: String?, suggested: String?) // running on a pulled runtime
    case none                                              // no runtime installed
}

extension RuntimeCatalog {
    public static func state(pinned: String?, resolved: String?, installed: [String], index: RuntimeIndex) -> BottleRuntimeState {
        let pulled = index.pulled
        let newestGood = installed.last { !pulled.contains($0) }
        if let resolved, pulled.contains(resolved) {
            return .onPulled(resolved, note: index.runtimes.first { $0.name == resolved }?.note, suggested: newestGood)
        }
        if let pinned {
            guard let at = installed.firstIndex(of: pinned) else { return .missingPin(pinned, using: resolved) }
            let newer = newestGood.flatMap { name in installed.firstIndex(of: name).map { $0 > at ? name : nil } } ?? nil
            return .pinned(pinned, newer: newer)
        }
        return resolved.map { .newest($0) } ?? .none
    }
}
