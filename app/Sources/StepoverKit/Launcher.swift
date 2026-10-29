import Foundation

/// Starts Wine in a bottle with the environment CrossOver's launcher would have given it.
public enum Launcher {
    /// Variables from the caller's environment that Wine must not see.
    static let dropped: Set<String> = ["NoDefaultCurrentDirectoryInExePath", "WINEPREFIX", "WINEDLLPATH",
                                       "WINEDLLOVERRIDES", "WINESERVER", "WINELOADER", "CX_ROOT"]

    public static func environment(bottle: Bottle, config: BottleConfig, runtime: Runtime,
                                   program: Program? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !dropped.contains($0.key) && !$0.key.hasPrefix("DYLD_") }
        env["WINEPREFIX"] = bottle.url.path
        env["WINESERVER"] = runtime.wineserver.path
        // CrossOver bottles keep their profile in C:\users\crossover; Wine derives it from USER.
        env["USER"] = "crossover"
        env["STEPOVER_COMPAT"] = bottle.compatURL.path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = runtime.libd3dshared.path  // as CrossOver: always, not only for D3DMetal
        env["DOTNET_EnableWriteXorExecute"] = "0"                          // .NET 7/8 under Rosetta, as CrossOver
        env["ROSETTA_ADVERTISE_AVX"] = "1"                                 // CrossOver's default
        env["MVK_CONFIG_LOG_LEVEL"] = env["MVK_CONFIG_LOG_LEVEL"] ?? "0"
        env["WINEDEBUG"] = env["STEPOVER_WINEDEBUG"] ?? "-all"
        env["WINEMSYNC"] = nil  // only the bottle decides: CrossOver runs without MSync unless WINEMSYNC=1
        for (key, value) in config.env { env[key] = value }
        if let program { for (key, value) in program.env { env[key] = value } }
        // CrossOver: any value of ROSETTA_ADVERTISE_AVX turns it on, so "0" means unset it.
        if env["ROSETTA_ADVERTISE_AVX"] == "0" || env["ROSETTA_ADVERTISE_AVX"] == "" { env["ROSETTA_ADVERTISE_AVX"] = nil }
        return env
    }

    /// Puts bottle-side files in place before a launch: the compat file, and D3DMetal's nvngx/nvapi64
    /// in system32 when MetalFX is on (Apple's Read Me; CrossOver redirects these instead).
    public static func prepare(bottle: Bottle, config: BottleConfig, runtime: Runtime) throws {
        let fixes = matchedFixes(bottle, config: config)
        try config.compatConf(fixes: fixes).write(to: bottle.compatURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)

        let metalFX = config.env["D3DM_ENABLE_METALFX"] == "1"
            || config.programs.contains { $0.env["D3DM_ENABLE_METALFX"] == "1" && config.backend(for: $0) == .d3dmetal }
            || config.processes.values.contains { $0.env["D3DM_ENABLE_METALFX"] == "1" }
            || fixes.contains { $0.fix.env["D3DM_ENABLE_METALFX"] == "1" && config.env["D3DM_ENABLE_METALFX"] == nil }
        guard metalFX else { return }
        let system32 = bottle.cDrive.appendingPathComponent("windows/system32")
        for dll in ["nvngx.dll", "nvapi64.dll"] {
            let source = runtime.d3dmetalWindowsDir.appendingPathComponent(dll)
            let target = system32.appendingPathComponent(dll)
            guard let wanted = try? Data(contentsOf: source) else { continue }
            if let current = try? Data(contentsOf: target), current == wanted { continue }
            let backup = system32.appendingPathComponent(dll + ".stepover-orig")
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: target, to: backup)
            }
            try? fm.removeItem(at: target)
            try wanted.write(to: target)
        }
    }

    public enum Output { case log, inherit }

    /// Runs `wine <arguments>` in the bottle. With wait=false the process gets its own session and
    /// outlives the caller (Mac launchers exit right away); the result is then its pid.
    @discardableResult
    public static func wine(_ arguments: [String], bottle: Bottle, program: Program? = nil,
                            workdir: URL? = nil, extraEnv: [String: String] = [:],
                            wait: Bool, output: Output = .log) throws -> Int32 {
        let (runtime, baseEnv) = try session(bottle, program: program)
        var env = baseEnv
        for (key, value) in extraEnv { env[key] = value }
        // A new bottle has no drive_c until Wine's first start creates it.
        let defaultDir = FileManager.default.fileExists(atPath: bottle.cDrive.path) ? bottle.cDrive : bottle.url
        return try spawn(runtime.wine.path, arguments, env: env, workdir: workdir ?? defaultDir,
                         log: output == .log ? bottle.logURL : nil, detach: !wait, wait: wait)
    }

    /// Readies the bottle for a Wine command (setup stamp, compat file, MetalFX files) and returns its
    /// runtime and environment. Everything that starts Wine goes through here.
    static func session(_ bottle: Bottle, program: Program? = nil) throws -> (Runtime, [String: String]) {
        var config = bottle.loadConfig()
        guard let runtime = bottle.runtime(config) else {
            throw StepoverError.message("No Wine runtime installed in \(Paths.runtimes.path)")
        }
        if let pinned = config.runtime, pinned != runtime.name {
            appendLog(bottle, "pinned runtime \(pinned) is missing; using \(runtime.name)")
        }
        if bottle.lastRuntime != runtime.name { bottle.lastRuntime = runtime.name }
        if !bottle.isRunning { config = try SetupStamp.reconcile(bottle, config, runtime: runtime) }
        try prepare(bottle: bottle, config: config, runtime: runtime)
        return (runtime, environment(bottle: bottle, config: config, runtime: runtime, program: program))
    }

    /// Waits until every Wine process in the bottle has ended (installers often hand off to a child).
    public static func waitUntilIdle(_ bottle: Bottle) throws {
        let config = bottle.loadConfig()
        guard let runtime = bottle.runtime(config) else { return }
        let env = environment(bottle: bottle, config: config, runtime: runtime)
        _ = try spawn(runtime.wineserver.path, ["-w"], env: env, workdir: bottle.url, log: nil, detach: false, wait: true)
    }

    /// Launches a program from stepover.json.
    @discardableResult
    public static func run(_ program: Program, in bottle: Bottle, extraArgs: [String] = [], wait: Bool = false,
                           output: Output = .log) throws -> Int32 {
        guard let exe = WindowsPath.toMac(program.exe, bottle: bottle), FileManager.default.fileExists(atPath: exe.path) else {
            throw StepoverError.message("\(program.name): \(program.exe) does not exist in \(bottle.name)")
        }
        let workdir = program.workdir.flatMap { WindowsPath.toMac($0, bottle: bottle) } ?? exe.deletingLastPathComponent()
        applyFixes(bottle)
        appendLog(bottle, "launching \(program.name): \(program.exe) \(program.args.joined(separator: " "))")
        let status = try wine([program.exe] + program.args + extraArgs, bottle: bottle, program: program,
                              workdir: workdir, wait: wait, output: output)
        RecentGames.record(program.name, bottle: bottle.name)
        return status
    }

    /// Stops every Wine process in the bottle.
    public static func stop(_ bottle: Bottle) throws {
        let config = bottle.loadConfig()
        guard let runtime = bottle.runtime(config) else { return }
        let env = environment(bottle: bottle, config: config, runtime: runtime)
        let status = try spawn(runtime.wineserver.path, ["-k"], env: env, workdir: bottle.url, log: nil, detach: false, wait: true)
        appendLog(bottle, "stopped the bottle (wineserver -k exited with \(status))")
    }

    /// Imports a REGEDIT4 patch with regedit inside the bottle.
    public static func importRegistry(_ patch: RegistryPatch, into bottle: Bottle) throws {
        let temp = bottle.cDrive.appendingPathComponent("windows/temp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appendingPathComponent("stepover-\(UUID().uuidString).reg")
        try patch.text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = try wine(["regedit", "/S", WindowsPath.toWindows(file, bottle: bottle)], bottle: bottle, wait: true)
        if status != 0 { throw StepoverError.message("regedit exited with \(status)") }
    }

    /// Sets High Resolution Mode and the Windows DPI, as CrossOver's bottle settings do.
    public static func setDisplay(highResolution: Bool, dpi: Int, bottle: Bottle) throws {
        var patch = RegistryPatch()
        patch.set(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", .string(highResolution ? "y" : "n"))
        patch.set(#"HKEY_CURRENT_USER\Control Panel\Desktop"#, "LogPixels", .dword(UInt32(dpi)))
        patch.set(#"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts"#, "LogPixels", .dword(UInt32(dpi)))
        try importRegistry(patch, into: bottle)
    }

    public static func appendLog(_ bottle: Bottle, _ line: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) stepover: \(line)\n"
        if let handle = try? FileHandle(forWritingTo: bottle.logURL) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: bottle.logURL, atomically: true, encoding: .utf8)
        }
    }

    /// posix_spawn with an explicit environment; returns the exit status (wait) or the pid.
    static func spawn(_ path: String, _ args: [String], env: [String: String], workdir: URL,
                      log: URL?, detach: Bool, wait: Bool) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let log {
            posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        }
        posix_spawn_file_actions_addchdir_np(&actions, workdir.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if detach { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) }

        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        guard rc == 0 else {
            throw StepoverError.message("could not start \(path) in \(workdir.path): \(String(cString: strerror(rc)))")
        }
        guard wait else { return pid }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { break } }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
