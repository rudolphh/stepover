import Foundation

/// The graphics translation layers a program can use. Raw values match CrossOver's
/// CX_ACTIVE_GRAPHICS_BACKEND names, which the Wine tree reads.
public enum Backend: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dmetal, dxmt, dxvk, wined3d
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }
    public var summary: String {
        switch self {
        case .d3dmetal: return "Apple's DirectX 11/12 to Metal, 64-bit games, MetalFX upscaling"
        case .dxmt: return "DirectX 10/11 to Metal, also for 32-bit games"
        case .dxvk: return "DirectX 9-11 through Vulkan (MoltenVK)"
        case .wined3d: return "Wine's own OpenGL path, for old games"
        }
    }
}

/// A launchable program in a bottle.
public struct Program: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// Windows path, e.g. C:\Games\RDR2\RDR2.exe
    public var exe: String
    public var args: [String]
    /// Windows path of the working directory; defaults to the exe's folder.
    public var workdir: String?
    /// nil = the bottle's default backend
    public var graphics: Backend?
    public var env: [String: String]

    public init(name: String, exe: String, args: [String] = [], workdir: String? = nil,
                graphics: Backend? = nil, env: [String: String] = [:]) {
        self.name = name; self.exe = exe; self.args = args; self.workdir = workdir
        self.graphics = graphics; self.env = env
    }

    /// File name of the exe, as the compat plug-in matches it.
    public var exeName: String { WindowsPath.fileName(exe) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        exe = try c.decode(String.self, forKey: .exe)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
        graphics = try c.decodeIfPresent(Backend.self, forKey: .graphics)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

/// Settings for a process that is not launched directly, e.g. a game started by its launcher.
public struct ProcessRule: Codable, Hashable, Sendable {
    public var graphics: Backend?
    public var env: [String: String]
    /// Appended to the process's command line by the compat plug-in (the process is started by
    /// another program, so Stepover can't pass them itself).
    public var args: [String]
    public init(graphics: Backend? = nil, env: [String: String] = [:], args: [String] = []) {
        self.graphics = graphics; self.env = env; self.args = args
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graphics = try c.decodeIfPresent(Backend.self, forKey: .graphics)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    }
}

/// <bottle>/stepover.json
public struct BottleConfig: Codable, Sendable {
    /// Runtime folder name in Paths.runtimes; nil = the newest installed runtime.
    public var runtime: String?
    /// Default backend for every process in the bottle.
    public var graphics: Backend
    /// Environment for every process in the bottle (WINEMSYNC, D3DM_*, ...).
    public var env: [String: String]
    public var programs: [Program]
    /// Extra per-process rules, keyed by exe file name.
    public var processes: [String: ProcessRule]
    /// Where the bottle came from, e.g. "CrossOver bottle RDR2 (2026-10-27)".
    public var origin: String?
    /// SHA-256 of the wine.inf the prefix was last set up with. Wine redoes the whole setup when
    /// wine.inf's mtime changes; with an identical file that only costs time and can break bottles
    /// with native .NET (a "could not be started" dialog), so the launcher skips it then.
    public var setupInf: String?
    /// Apply BuiltInFixes beneath this bottle's rules (default true; false turns them all off).
    public var builtInFixes = true
    /// Apply fixes from the fix list (official, added sources, your own); default true.
    public var fixes = true
    /// Fix ids (FixLibrary "<source>/<file>") turned off for this bottle.
    public var disabledFixes: [String] = []
    /// Registry values from fixes already written into this bottle ("<key>\<name>=<value>").
    public var appliedRegistry: [String] = []
    /// Components a fix asked for that winetricks failed to install; not retried automatically
    /// (installing one from Components tries again).
    public var failedComponents: [String] = []

    public init(runtime: String? = nil, graphics: Backend = .d3dmetal, env: [String: String] = [:],
                programs: [Program] = [], processes: [String: ProcessRule] = [:], origin: String? = nil) {
        self.runtime = runtime; self.graphics = graphics; self.env = env
        self.programs = programs; self.processes = processes; self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        graphics = try c.decodeIfPresent(Backend.self, forKey: .graphics) ?? .d3dmetal
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        programs = try c.decodeIfPresent([Program].self, forKey: .programs) ?? []
        processes = try c.decodeIfPresent([String: ProcessRule].self, forKey: .processes) ?? [:]
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        setupInf = try c.decodeIfPresent(String.self, forKey: .setupInf)
        builtInFixes = try c.decodeIfPresent(Bool.self, forKey: .builtInFixes) ?? true
        fixes = try c.decodeIfPresent(Bool.self, forKey: .fixes) ?? true
        disabledFixes = try c.decodeIfPresent([String].self, forKey: .disabledFixes) ?? []
        appliedRegistry = try c.decodeIfPresent([String].self, forKey: .appliedRegistry) ?? []
        failedComponents = try c.decodeIfPresent([String].self, forKey: .failedComponents) ?? []
    }

    /// The backend a program ends up with.
    public func backend(for program: Program) -> Backend { program.graphics ?? graphics }

    /// MSync, CrossOver's macOS sync primitives: on only with WINEMSYNC=1 (new bottles get it, like
    /// CrossOver's bottle template).
    public var msync: Bool {
        get { env["WINEMSYNC"] == "1" }
        set { env["WINEMSYNC"] = newValue ? "1" : "0" }
    }

    /// The text of stepover-compat.conf, which the compat plug-in reads in every Wine process.
    /// One program's settings in stepover-compat.conf; later layers win over earlier ones.
    struct Section {
        var backend: Backend?
        var env: [String: String] = [:]
        var dlls: [String: String] = [:]
        var args: [String] = []

        mutating func layer(backend: Backend?, env: [String: String] = [:], dlls: [String: String] = [:], args: [String] = []) {
            self.backend = backend ?? self.backend
            self.env.merge(env) { _, new in new }
            self.dlls.merge(dlls) { _, new in new }
            self.args += args.filter { !self.args.contains($0) }
        }
    }

    /// The stepover-compat.conf format this app writes (STEPOVER_COMPAT_FORMAT in compat/stepovercompat.c).
    public static let compatFormat = 3

    /// The text of stepover-compat.conf, which the compat plug-in reads in every Wine process.
    /// Layers, lowest first: built-in fixes, matched community fixes, programs, the bottle's rules.
    public func compatConf(fixes: [MatchedFix] = []) -> String {
        var out = "# Written by Stepover from stepover.json; edit that file (or use the app) instead.\n\n"
            + "version = \(Self.compatFormat)\n\n[*]\nbackend = \(graphics.rawValue)\n"
        var sections: [String: Section] = [:]
        for fix in builtInFixes ? BuiltInFixes.all : [] {
            sections[fix.exe.asciiLowercased, default: Section()].layer(backend: fix.rule.graphics, env: fix.rule.env, args: fix.rule.args)
        }
        // The bottle's own environment and DLL overrides reach every process from the launcher; a fix
        // must not override them (the plug-in's settings would).
        let bottleDlls = Self.overriddenDlls(env["WINEDLLOVERRIDES"])
        for matched in fixes {
            let fix = matched.fix
            let fixEnv = fix.env.filter { env[$0.key] == nil }
            let fixDlls = fix.dlls.filter { !bottleDlls.contains($0.key.asciiLowercased) }
            for key in matched.programs {
                sections[key, default: Section()].layer(backend: fix.graphics.flatMap(Backend.init(rawValue:)), env: fixEnv, dlls: fixDlls)
            }
            for key in matched.argPrograms { sections[key, default: Section()].layer(backend: nil, args: fix.args) }
        }
        // The user's own rules, by file name
        var user: [String: Section] = [:]
        // A program's own WINEDLLOVERRIDES also goes out as dll lines: Wine reads the variable before the plug-in
        // can set it, while the plug-in hands dll lines to the loader directly.
        for program in programs {
            user[program.exeName.asciiLowercased, default: Section()].layer(
                backend: program.graphics, env: program.env, dlls: Self.dllOverrides(program.env["WINEDLLOVERRIDES"]))
        }
        for (exe, rule) in processes {
            user[exe.asciiLowercased, default: Section()].layer(
                backend: rule.graphics, env: rule.env, dlls: Self.dllOverrides(rule.env["WINEDLLOVERRIDES"]), args: rule.args)
        }
        for (key, rule) in user {
            let mine = Self.overriddenDlls(rule.env["WINEDLLOVERRIDES"])
            sections[key, default: Section()].dlls = (sections[key]?.dlls ?? [:]).filter { !mine.contains($0.key.asciiLowercased) }
            sections[key]!.layer(backend: rule.backend, env: rule.env, dlls: rule.dlls, args: rule.args)
        }
        // A Steam fix's section is named by the game's full path. The plug-in applies every matching
        // section in file order, so full paths go last and also carry the user's rules for that file
        // name: the user's settings win either way.
        for key in sections.keys where key.contains("\\") {
            let fileName = String(key.split(separator: "\\").last ?? "")
            guard let rule = user[fileName] else { continue }
            let mine = Self.overriddenDlls(rule.env["WINEDLLOVERRIDES"])
            sections[key]!.dlls = sections[key]!.dlls.filter { !mine.contains($0.key.asciiLowercased) }
            sections[key]!.layer(backend: rule.backend, env: rule.env, dlls: rule.dlls, args: rule.args)
        }
        // Section names come from fixes, Steam folders and the user; one that could close the
        // section header or start new lines is left out instead of written.
        let ordered = sections.keys.filter { !$0.contains("\\") }.sorted() + sections.keys.filter { $0.contains("\\") }.sorted()
        for key in ordered where Self.isSectionName(key) {
            let section = sections[key]!
            out += "\n[\(key)]\n"
            out += "backend = \((section.backend ?? graphics).rawValue)\n"
            for name in section.env.keys.sorted() where Self.isOneLine(name + section.env[name]!) {
                out += "env = \(name)=\(section.env[name]!)\n"
            }
            for dll in section.dlls.keys.sorted() { out += "dll = \(Fix.wineOverride(dll, section.dlls[dll]!))\n" }
            // appended as raw text to the command line; a line break would start a new INI line
            for arg in section.args where Self.isOneLine(arg) { out += "args = \(arg)\n" }
        }
        return out
    }

    static func isOneLine(_ s: String) -> Bool { !s.contains { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) } }

    static func isSectionName(_ key: String) -> Bool {
        !key.isEmpty && key != "*" && isOneLine(key) && !key.contains("[") && !key.contains("]")
    }

    /// A WINEDLLOVERRIDES value as fix-style load orders: "d3d9,ddraw=n,b;dinput8=" gives d3d9 and ddraw
    /// "native,builtin", dinput8 "disabled". Entries with a load order Wine wouldn't take are left out.
    static func dllOverrides(_ value: String?) -> [String: String] {
        guard let value else { return [:] }
        var out: [String: String] = [:]
        for entry in value.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let raw = parts[1].trimmingCharacters(in: .whitespaces).asciiLowercased
            let order: String
            if raw.isEmpty || raw == "d" || raw == "disabled" {
                order = "disabled"
            } else {
                let modes = raw.split(separator: ",").map { $0 == "n" || $0 == "native" ? "native" : $0 == "b" || $0 == "builtin" ? "builtin" : "" }
                guard !modes.contains("") else { continue }
                order = modes.joined(separator: ",")
            }
            for name in parts[0].split(separator: ",") {
                var dll = name.trimmingCharacters(in: .whitespaces).asciiLowercased
                if dll.hasSuffix(".dll") { dll.removeLast(4) }
                if !dll.isEmpty && isOneLine(dll) { out[dll] = order }
            }
        }
        return out
    }

    /// DLL names in a WINEDLLOVERRIDES value ("d3d9,ddraw=n,b;dinput8=d").
    static func overriddenDlls(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        var out = Set<String>()
        for entry in value.split(separator: ";") {
            for name in (entry.split(separator: "=", maxSplits: 1).first ?? "").split(separator: ",") {
                var dll = name.trimmingCharacters(in: .whitespaces).asciiLowercased
                if dll.hasSuffix(".dll") { dll.removeLast(4) }
                out.insert(dll)
            }
        }
        return out
    }

    /// Which of `fixes` apply here: those whose game is found, by Steam install or by program file.
    /// `programs`: lowercased program file names in the bottle (Launcher.programNames);
    /// `steamApps`: games installed through Steam in it.
    public func matchedFixes(_ fixes: [Fix], programs: Set<String>, steamApps: [SteamApp]) -> [MatchedFix] {
        guard self.fixes else { return [] }
        var out: [MatchedFix] = []
        var claimedSteam = Set<Int>(), claimedExes = Set<String>()
        // One fix per game: `fixes` come in load order (official converted, official hand-written,
        // added sources, your own), and the last one for a Steam ID or program name wins. A fix
        // turned off still claims its game, so an older one doesn't take its place.
        for fix in fixes.reversed() {
            let exes = fix.match.exe.map(\.asciiLowercased)
            let installed = steamApps.filter { fix.match.steam.contains($0.id) }
            let found = exes.filter(programs.contains)
            guard !installed.isEmpty || !found.isEmpty else { continue }
            if !claimedSteam.isDisjoint(with: fix.match.steam) || !claimedExes.isDisjoint(with: exes) { continue }
            claimedSteam.formUnion(fix.match.steam)
            claimedExes.formUnion(exes)
            guard !disabledFixes.contains(fix.id) else { continue }

            // Steam games: settings go to the game's own files by full path, so a generic name such as
            // launcher.exe in one game doesn't pick up another game's fix.
            var keys: [String] = [], argKeys: [String] = []
            for app in installed {
                let all = app.programs(), top = Set(app.topPrograms())
                let chosen = exes.isEmpty ? all : all.filter { exes.contains($0.lastPathComponent.asciiLowercased) }
                keys += chosen.map(app.windowsKey)
                argKeys += (exes.isEmpty ? chosen.filter(top.contains) : chosen).map(app.windowsKey)
            }
            keys += found
            argKeys += found
            guard !keys.isEmpty else { continue }
            out.append(MatchedFix(fix: fix, programs: Array(Set(keys)).sorted(), argPrograms: Array(Set(argKeys)).sorted()))
        }
        return out.reversed()
    }
}
