import Foundation

/// Installing Windows software into a bottle: a program's own installer, or runtime components
/// (.NET, Visual C++ and the like) through winetricks.
public enum WindowsSetup {
    /// Runs a setup .exe or .msi from anywhere on the Mac, waits for it and everything it started,
    /// then adds the programs whose Start Menu or desktop shortcuts appeared (as CrossOver does).
    @discardableResult
    public static func install(_ file: URL, into bottle: Bottle, arguments: [String] = [],
                               output: Launcher.Output = .log) throws -> [Program] {
        let before = Set(Importer.programs(in: bottle).map { $0.exe.lowercased() })
        let windows = WindowsPath.toWindows(file, bottle: bottle)
        let args = (file.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", windows] : [windows]) + arguments
        Launcher.appendLog(bottle, "installing \(file.path)")
        _ = try Launcher.wine(args, bottle: bottle, workdir: file.deletingLastPathComponent(), wait: true, output: output)
        try Launcher.waitUntilIdle(bottle)

        var config = bottle.loadConfig()
        let known = Set(config.programs.map { $0.exe.lowercased() })
        let added = Importer.programs(in: bottle).filter { !before.contains($0.exe.lowercased()) && !known.contains($0.exe.lowercased()) }
        if !added.isEmpty {
            config.programs += added
            try bottle.save(config)
        }
        Launcher.appendLog(bottle, "installer finished; new programs: \(added.map(\.name).joined(separator: ", "))")
        return added
    }

    public struct Component: Identifiable, Hashable, Sendable {
        public var id: String { verb }
        public let verb: String, title: String, detail: String
    }

    /// The winetricks verbs games ask for most.
    public static let commonComponents: [Component] = [
        Component(verb: "vcrun2022", title: "Visual C++ 2015-2022", detail: "The runtime most modern games need"),
        Component(verb: "dotnet48", title: ".NET Framework 4.8", detail: "Mods and older launchers; takes several minutes"),
        Component(verb: "dotnetdesktop8", title: ".NET 8 Desktop Runtime", detail: "Newer .NET apps and launchers"),
        Component(verb: "d3dx9", title: "DirectX 9 extras (d3dx9)", detail: "Older games that complain about d3dx9_*.dll"),
        Component(verb: "d3dcompiler_47", title: "D3D shader compiler 47", detail: "Games that compile shaders at runtime"),
        Component(verb: "xact", title: "XACT / XAudio", detail: "Missing sound in older games"),
        Component(verb: "physx", title: "NVIDIA PhysX", detail: "Games that need PhysX's CPU runtime"),
        Component(verb: "corefonts", title: "Microsoft core fonts", detail: "Arial, Times and friends"),
    ]

    /// STEPOVER_WINETRICKS, else Homebrew's winetricks.
    public static var winetricks: URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["STEPOVER_WINETRICKS"], "/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"]
        return candidates.compactMap { $0 }.filter { !$0.isEmpty }.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Installs winetricks verbs into the bottle with the bottle's own Wine; returns winetricks' exit status.
    @discardableResult
    public static func installComponents(_ verbs: [String], into bottle: Bottle, output: Launcher.Output = .log) throws -> Int32 {
        guard let winetricks else {
            throw StepoverError.message("winetricks is not installed (brew install winetricks)")
        }
        guard !verbs.isEmpty, verbs.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.=-]+$"#, options: .regularExpression) != nil }) else {
            throw StepoverError.message("not a winetricks verb: \(verbs.joined(separator: " "))")
        }
        let (runtime, baseEnv) = try Launcher.session(bottle)
        var env = baseEnv
        env["WINE"] = runtime.wine.path
        env["WINESERVER"] = runtime.wineserver.path
        env["W_OPT_UNATTENDED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        Launcher.appendLog(bottle, "winetricks \(verbs.joined(separator: " "))")
        let status = try Launcher.spawn(winetricks.path, ["-q"] + verbs, env: env, workdir: bottle.url,
                                        log: output == .log ? bottle.logURL : nil, detach: false, wait: true)
        try Launcher.waitUntilIdle(bottle)
        return status
    }
}
