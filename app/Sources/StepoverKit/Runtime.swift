import Foundation

/// An installed Wine runtime (built by ~/.local/src/stepover/runtime/install-runtime.sh).
public struct Runtime: Hashable, Sendable {
    public let url: URL
    public var name: String { url.lastPathComponent }
    public var wine: URL { url.appendingPathComponent("bin/wine") }
    public var wineserver: URL { url.appendingPathComponent("bin/wineserver") }
    public var lib: URL { url.appendingPathComponent("lib") }
    public var d3dmetalWindowsDir: URL { lib.appendingPathComponent("d3dmetal/wine/x86_64-windows") }
    public var libd3dshared: URL { lib.appendingPathComponent("d3dmetal/external/libd3dshared.dylib") }
    public var wineInf: URL { url.appendingPathComponent("share/wine/wine.inf") }

    /// key=value lines of the runtime's VERSION file
    public var info: [String: String] {
        guard let text = try? String(contentsOf: url.appendingPathComponent("VERSION"), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    public var summary: String {
        let i = info
        var text = "\(i["wine"] ?? name), D3DMetal \(i["d3dmetal"] ?? "?"), DXMT \(i["dxmt"] ?? "?")"
        if let dxvk = i["dxvk"], dxvk != "none" { text += ", DXVK \(dxvk)" }
        return text
    }

    public static func installed() -> [Runtime] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Paths.runtimes.path)) ?? []
        return ordered(names)
            .map { Runtime(url: Paths.runtimes.appendingPathComponent($0)) }
            .filter { fm.isExecutableFile(atPath: $0.wine.path) }
    }

    /// Runtime folder names, oldest first: cx26.3, cx26.3-2 (a rebuild), cx26.3-10, cx26.4. Leaves out
    /// hidden names and the installers' .new and .old folders.
    public static func ordered(_ names: [String]) -> [String] {
        names
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".new") && !$0.hasSuffix(".old") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Which installed runtime a bottle runs on; the first rule that matches wins: its pinned runtime,
    /// STEPOVER_RUNTIME, the pulled runtime it last ran on (a bottle is never moved off a runtime by
    /// itself), the newest that isn't pulled, the newest. `installed` is oldest first (`ordered`).
    public static func choose(pinned: String?, lastUsed: String?, installed: [String], pulled: Set<String>,
                              preferred: String?) -> String? {
        if let pinned, installed.contains(pinned) { return pinned }
        if let preferred, installed.contains(preferred) { return preferred }
        if let lastUsed, pulled.contains(lastUsed), installed.contains(lastUsed) { return lastUsed }
        return installed.last { !pulled.contains($0) } ?? installed.last
    }

    /// The named runtime, else STEPOVER_RUNTIME, else the newest installed one that isn't pulled.
    public static func resolve(_ name: String?) -> Runtime? { resolve(pinned: name, lastUsed: nil) }

    static func resolve(pinned: String?, lastUsed: String?) -> Runtime? {
        let all = installed()
        let name = choose(pinned: pinned, lastUsed: lastUsed, installed: all.map(\.name),
                          pulled: RuntimeIndex.load().pulled, preferred: Paths.defaultRuntimeName)
        return all.first { $0.name == name }
    }
}
