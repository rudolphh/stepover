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
    public func compatConf() -> String {
        var out = "# Written by Stepover from stepover.json; edit that file (or use the app) instead.\n\n[*]\nbackend = \(graphics.rawValue)\n"
        var sections: [String: (Backend?, [String: String], [String])] = [:]
        for fix in builtInFixes ? BuiltInFixes.all : [] {
            sections[fix.exe.lowercased()] = (fix.rule.graphics, fix.rule.env, fix.rule.args)
        }
        for program in programs {
            let key = program.exeName.lowercased()
            let existing = sections[key]
            sections[key] = (program.graphics ?? existing?.0, (existing?.1 ?? [:]).merging(program.env) { _, new in new },
                             existing?.2 ?? [])
        }
        for (exe, rule) in processes {
            let key = exe.lowercased()
            let existing = sections[key]
            let args = existing?.2 ?? []
            sections[key] = (rule.graphics ?? existing?.0, (existing?.1 ?? [:]).merging(rule.env) { _, new in new },
                             args + rule.args.filter { !args.contains($0) })
        }
        for key in sections.keys.sorted() {
            let (backend, env, args) = sections[key]!
            out += "\n[\(key)]\n"
            out += "backend = \((backend ?? graphics).rawValue)\n"
            for name in env.keys.sorted() { out += "env = \(name)=\(env[name]!)\n" }
            // appended as raw text to the command line; a line break would start a new INI line
            for arg in args where !arg.contains(where: \.isNewline) { out += "args = \(arg)\n" }
        }
        return out
    }
}
