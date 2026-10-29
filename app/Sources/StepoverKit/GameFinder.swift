import Foundation

/// An .exe in an installed game's folder, as GameFinder weighs it.
public struct ExeCandidate: Equatable, Sendable {
    public var path: String            // relative to the game folder, "/"-separated
    public var size: Int64
    public var windowed: Bool
    public var graphics: Bool          // imports d3d9, d3d11, d3d12, dxgi, opengl32 or vulkan-1
    public var fromShortcut: Bool

    public init(path: String, size: Int64, windowed: Bool, graphics: Bool, fromShortcut: Bool) {
        self.path = path; self.size = size; self.windowed = windowed; self.graphics = graphics; self.fromShortcut = fromShortcut
    }

    var fileName: String { String(path.split(separator: "/").last ?? "") }
    var isTopLevel: Bool { !path.contains("/") }
}

/// Which program in an installed game's folder is the game, not its uninstaller (spec D7).
public enum GameFinder {
    static let excludedPrefixes = ["unins", "uninstall", "setup", "install", "vc_redist", "vcredist", "dxsetup", "dxwebsetup",
                                   "ue4prereqsetup", "ueprereqsetup", "quicksfv", "dotnetfx", "oalinst", "physx", "crashpad"]
    static let excludedWords = ["redist", "crashreport", "crashhandler", "config", "settings"]
    static let graphicsDLLs: Set<String> = ["d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll",
                                            "ddraw.dll", "opengl32.dll", "vulkan-1.dll"]

    /// Uninstallers, installers, redistributables, crash reporters, and settings or config tools.
    public static func isExcluded(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        return excludedPrefixes.contains { name.hasPrefix($0) } || excludedWords.contains { name.contains($0) }
    }

    /// Best first: an exe the games list names; a shortcut's target; a top-level exe named like the game (its initials
    /// count: RDR2); the only top-level exe; then one that loads graphics, then the largest. Excluded and console
    /// programs never appear.
    public static func rank(_ candidates: [ExeCandidate], gameName: String, knownExes: [String]) -> [ExeCandidate] {
        let known = Set(knownExes.map { $0.lowercased() })
        let usable = candidates.filter { $0.windowed && !isExcluded($0.fileName) }
        let topLevel = usable.filter(\.isTopLevel).count
        func score(_ c: ExeCandidate) -> [Int64] {
            [known.contains(c.fileName.lowercased()) ? 1 : 0,
             c.fromShortcut ? 1 : 0,
             c.isTopLevel ? Int64(resemblance(c.fileName, gameName)) : 0,
             c.isTopLevel && topLevel == 1 ? 1 : 0,
             c.isTopLevel ? 1 : 0,
             c.graphics ? 1 : 0,
             c.size]
        }
        return usable.sorted { a, b in
            let (x, y) = (score(a), score(b))
            return x != y ? x.lexicographicallyPrecedes(y, by: >) : a.path < b.path
        }
    }

    /// 2: the exe's name is the game's name or its initials ("RDR2"); 1: one holds the other; 0: neither.
    static func resemblance(_ fileName: String, _ gameName: String) -> Int {
        func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let exe = letters((fileName as NSString).deletingPathExtension)
        let words = GameName.normalized(gameName, dropEdition: false).split(separator: " ")
        let game = words.joined()
        let initials = words.map { $0.allSatisfy(\.isNumber) ? String($0) : String($0.prefix(1)) }.joined()
        guard !exe.isEmpty, !game.isEmpty else { return 0 }
        if exe == game || (initials.count >= 2 && exe == initials) { return 2 }
        if exe.count >= 3 && (game.contains(exe) || exe.contains(game) || exe.contains(initials) && initials.count >= 3) { return 1 }
        return 0
    }

    /// Every .exe up to five folders down, read for the ranking; `shortcuts` are Windows paths of new shortcuts' targets.
    public static func candidates(in folder: URL, shortcuts: [String]) -> [ExeCandidate] {
        let targets = shortcuts.map { $0.lowercased() }
        return GameFolder.files(in: folder, levels: 6).filter { $0.pathExtension.lowercased() == "exe" }.compactMap { url in
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pe = PEFile(url: url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let windowsTail = "\\" + relative.replacingOccurrences(of: "/", with: "\\").lowercased()
            return ExeCandidate(path: relative, size: size, windowed: pe?.isWindowed ?? false,
                                graphics: !(pe?.imports.isDisjoint(with: graphicsDLLs) ?? true),
                                fromShortcut: targets.contains { $0.hasSuffix(windowsTail) })
        }
    }
}

/// What a game's files ask for that Wine's own DLLs don't cover (spec D6): installed through winetricks instead of
/// running the bundled redistributable installers, which hang under Wine.
public enum NeededComponents {
    /// winetricks verbs for DLLs the game's files import and the game doesn't ship, sorted.
    public static func verbs(imports: Set<String>, shipped: Set<String>) -> [String] {
        let have = Set(shipped.map { $0.lowercased() })
        var verbs = Set<String>()
        for dll in imports.map({ $0.lowercased() }) where !have.contains(dll) {
            if let verb = verb(for: dll) { verbs.insert(verb) }
        }
        return verbs.sorted()
    }

    static func verb(for dll: String) -> String? {
        switch dll {
        case "d3dx11_42.dll": return "d3dx11_42"
        case "d3dx11_43.dll": return "d3dx11_43"
        case "d3dcompiler_42.dll": return "d3dcompiler_42"
        case "d3dcompiler_43.dll": return "d3dcompiler_43"
        case "physxloader.dll", "physxcore.dll": return "physx"
        default: break
        }
        if dll.hasPrefix("d3dx9_") { return "d3dx9" }
        if dll.hasPrefix("d3dx10") { return "d3dx10" }
        if dll.hasPrefix("xactengine") || dll.hasPrefix("x3daudio") || dll.hasPrefix("xapofx") { return "xact" }
        return nil
    }

    /// The imports of every .exe and .dll in the folder (at most 2,000 files) and the DLLs the game ships, lowercased.
    public static func scan(_ folder: URL) -> (imports: Set<String>, shipped: Set<String>) {
        let files = GameFolder.files(in: folder, levels: 8).filter { ["exe", "dll"].contains($0.pathExtension.lowercased()) }.prefix(2_000)
        var imports = Set<String>()
        for file in files { imports.formUnion(PEFile(url: file)?.imports ?? []) }
        let shipped = Set(files.filter { $0.pathExtension.lowercased() == "dll" }.map { $0.lastPathComponent.lowercased() })
        return (imports, shipped)
    }

    /// The game ships NVIDIA DLSS: MetalFX stands in for it (spec D8).
    public static func shipsDLSS(_ shipped: Set<String>) -> Bool { shipped.contains("nvngx_dlss.dll") }
}
