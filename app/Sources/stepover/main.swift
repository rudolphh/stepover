import StepoverKit
import Foundation

let usage = """
usage: stepover <command> ...

  list                                  bottles, their programs and graphics backends
  run <bottle> [<program>] [--wait] [-- args...]
                                        start a program (by name from stepover.json, or a C:\\ path)
  wine <bottle> <args...>               run any Wine command in the bottle and wait (winecfg, regedit...)
  stop <bottle>                         end every Wine process in the bottle
  import <crossover bottle> [--as <name>]
                                        copy a CrossOver bottle into Stepover (CrossOver's stays as is)
  create <name>                         new empty Windows 10 bottle
  graphics <bottle> <program|*> <d3dmetal|dxmt|dxvk|wined3d|auto>
  env <bottle> [<program>] NAME=value | NAME=
  display <bottle> [--high-res on|off] [--dpi 96|144|192]
  pick <exe file>                       which backend Stepover would choose, and why
  make-app <bottle> <program>           Mac app in \(Paths.launchers.path)
  install <bottle> <setup.exe|.msi> [-- installer args]
                                        run a Windows installer; its new shortcuts become programs
  components <bottle> <verb...>         install runtime components with winetricks (vcrun2022, dotnet48...)
  components                            list the common ones
  runtime [status|install [--from <file or URL>]]
                                        the Wine runtime the app downloads on first launch
  runtimes                              installed Wine runtimes

Environment: STEPOVER_HOME, STEPOVER_BOTTLES, STEPOVER_RUNTIMES, STEPOVER_RUNTIME, STEPOVER_LOGS,
STEPOVER_LAUNCHERS, STEPOVER_CROSSOVER_BOTTLES, STEPOVER_WINEDEBUG.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stepover: \(message)\n".utf8))
    exit(1)
}

func bottle(_ name: String) -> Bottle {
    guard let b = Bottle.named(name) else { fail("no bottle named \(name) in \(Paths.bottles.path)") }
    return b
}

func program(_ name: String, in config: BottleConfig) -> Program? {
    config.programs.first { $0.name == name } ?? config.programs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

do {
    switch command {
    case "list":
        for b in Bottle.all() {
            let config = b.loadConfig()
            let runtime = b.runtime(config)?.name ?? "no runtime"
            print("\(b.name)\(b.isRunning ? "  [running]" : "")  (default \(config.graphics.label), \(runtime), MSync \(config.msync ? "on" : "off"), high res \(b.highResolution ? "on" : "off"), \(b.dpi) dpi)")
            for p in config.programs {
                print("  \(p.name): \(config.backend(for: p).label)  \(p.exe)\(p.env.isEmpty ? "" : "  " + p.env.map { "\($0)=\($1)" }.sorted().joined(separator: " "))")
            }
        }

    case "run":
        guard let name = args.first else { fail("run needs a bottle") }
        let b = bottle(name)
        let config = b.loadConfig()
        var rest = Array(args.dropFirst())
        var extra: [String] = []
        if let dash = rest.firstIndex(of: "--") { extra = Array(rest[(dash + 1)...]); rest = Array(rest[..<dash]) }
        let wait = rest.contains("--wait")
        rest.removeAll { $0 == "--wait" }
        let target: Program
        if let which = rest.first {
            if let p = program(which, in: config) { target = p }
            else if which.contains(":\\") || which.lowercased().hasSuffix(".exe") { target = Program(name: WindowsPath.fileName(which), exe: which) }
            else { fail("\(b.name) has no program named \(which); try `stepover list`") }
        } else if config.programs.count == 1 {
            target = config.programs[0]
        } else {
            fail("\(b.name) has \(config.programs.count) programs; name one")
        }
        let result = try Launcher.run(target, in: b, extraArgs: extra, wait: wait, output: wait ? .inherit : .log)
        if wait { exit(result) }
        print("started \(target.name) (pid \(result)); log: \(b.logURL.path)")

    case "wine":
        guard args.count >= 2 else { fail("wine needs a bottle and a command") }
        exit(try Launcher.wine(Array(args.dropFirst()), bottle: bottle(args[0]), wait: true, output: .inherit))

    case "stop":
        guard let name = args.first else { fail("stop needs a bottle") }
        try Launcher.stop(bottle(name))

    case "import":
        guard let name = args.first else { fail("import needs a CrossOver bottle name") }
        var newName: String?
        if let i = args.firstIndex(of: "--as"), i + 1 < args.count { newName = args[i + 1] }
        let b = try Importer.importCrossOver(name, as: newName)
        let config = b.loadConfig()
        print("imported \(name) as \(b.name): default \(config.graphics.label), env \(config.env.map { "\($0)=\($1)" }.sorted().joined(separator: " "))")
        for p in config.programs { print("  \(p.name): \(config.backend(for: p).label)  \(p.exe)") }

    case "create":
        guard let name = args.first else { fail("create needs a name") }
        let b = try Importer.create(name)
        print("created \(b.url.path)")

    case "graphics":
        guard args.count == 3 else { fail("graphics <bottle> <program|*> <backend|auto>") }
        let b = bottle(args[0])
        var config = b.loadConfig()
        let choice = args[2].lowercased()
        if args[1] == "*" {
            guard let backend = Backend(rawValue: choice) else { fail("unknown backend \(choice)") }
            config.graphics = backend
        } else {
            guard let i = config.programs.firstIndex(where: { $0.name.caseInsensitiveCompare(args[1]) == .orderedSame }) else {
                fail("\(b.name) has no program named \(args[1])")
            }
            if choice == "auto", let exe = WindowsPath.toMac(config.programs[i].exe, bottle: b) {
                let pick = GraphicsPicker.pick(exe: exe)
                config.programs[i].graphics = pick.backend
                print(pick.reason)
            } else {
                guard let backend = Backend(rawValue: choice) else { fail("unknown backend \(choice)") }
                config.programs[i].graphics = backend
            }
        }
        try b.save(config)

    case "env":
        guard args.count >= 2 else { fail("env <bottle> [<program>] NAME=value") }
        let b = bottle(args[0])
        var config = b.loadConfig()
        let assignment = args.last!
        guard let eq = assignment.firstIndex(of: "=") else { fail("expected NAME=value") }
        let key = String(assignment[..<eq]), value = String(assignment[assignment.index(after: eq)...])
        if args.count == 3 {
            guard let i = config.programs.firstIndex(where: { $0.name.caseInsensitiveCompare(args[1]) == .orderedSame }) else {
                fail("\(b.name) has no program named \(args[1])")
            }
            config.programs[i].env[key] = value.isEmpty ? nil : value
        } else {
            config.env[key] = value.isEmpty ? nil : value
        }
        try b.save(config)

    case "display":
        guard let name = args.first else { fail("display needs a bottle") }
        let b = bottle(name)
        var highRes = b.highResolution, dpi = b.dpi
        if let i = args.firstIndex(of: "--high-res"), i + 1 < args.count { highRes = args[i + 1] == "on" }
        if let i = args.firstIndex(of: "--dpi"), i + 1 < args.count, let n = Int(args[i + 1]) { dpi = n }
        try Launcher.setDisplay(highResolution: highRes, dpi: dpi, bottle: b)
        print("\(b.name): high resolution \(highRes ? "on" : "off"), \(dpi) dpi")

    case "pick":
        guard let path = args.first else { fail("pick needs an exe") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let pick = GraphicsPicker.pick(exe: url)
        if let pe = PEFile(url: url) {
            print("\(pe.is64Bit ? "64-bit" : "32-bit"); graphics imports: \(pe.imports.filter { $0.hasPrefix("d3d") || $0 == "dxgi.dll" || $0.hasPrefix("vulkan") || $0 == "opengl32.dll" || $0 == "ddraw.dll" }.sorted())")
        }
        print("\(pick.backend.label): \(pick.reason)\(pick.env.isEmpty ? "" : " " + pick.env.map { "\($0)=\($1)" }.joined(separator: " "))")

    case "make-app":
        guard args.count == 2 else { fail("make-app <bottle> <program>") }
        let b = bottle(args[0])
        guard let p = program(args[1], in: b.loadConfig()) else { fail("\(b.name) has no program named \(args[1])") }
        print(try MacLauncher.create(for: p, in: b).path)

    case "runtimes":
        for r in Runtime.installed() { print("\(r.name): \(r.summary)  (\(r.url.path))") }

    case "runtime":
        let sub = args.first ?? "status"
        guard var manifest = RuntimeManifest.bundled() else {
            fail("this build has no runtime.json (set STEPOVER_RUNTIME_MANIFEST)")
        }
        switch sub {
        case "status":
            let state = manifest.isCurrent ? "installed, up to date"
                : manifest.isInstalled ? "installed, update available (stepover runtime install)" : "not installed"
            print("\(manifest.name): \(state) (\(manifest.size / 1_000_000) MB download from \(manifest.url))")
        case "install":
            if let i = args.firstIndex(of: "--from"), i + 1 < args.count { manifest.url = args[i + 1] }
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<Runtime, Error> = .failure(StepoverError.message("not started"))
            Task.detached {
                do {
                    let runtime = try await RuntimeInstaller.install(manifest) { fraction in
                        FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", fraction * 100).utf8))
                    }
                    outcome = .success(runtime)
                } catch { outcome = .failure(error) }
                semaphore.signal()
            }
            semaphore.wait()
            FileHandle.standardError.write(Data("\n".utf8))
            print("installed \(try outcome.get().summary)")
        default:
            fail("runtime status | runtime install [--from <file or URL>]")
        }

    case "install":
        var installerArgs: [String] = []
        if let dash = args.firstIndex(of: "--") { installerArgs = Array(args[(dash + 1)...]); args = Array(args[..<dash]) }
        guard args.count == 2 else { fail("install <bottle> <setup.exe or .msi> [-- installer args]") }
        let b = bottle(args[0])
        let file = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: file.path) else { fail("no such file: \(file.path)") }
        let added = try WindowsSetup.install(file, into: b, arguments: installerArgs, output: .inherit)
        if added.isEmpty { print("installer finished; no new Start Menu or desktop shortcuts, so add the program with the app") }
        for p in added { print("added \(p.name): \(b.loadConfig().backend(for: p).label)  \(p.exe)") }

    case "components":
        guard let name = args.first else {
            for c in WindowsSetup.commonComponents { print("\(c.verb.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.title): \(c.detail)") }
            print("winetricks: \(WindowsSetup.winetricks?.path ?? "not installed (brew install winetricks)")")
            exit(0)
        }
        let verbs = Array(args.dropFirst())
        guard !verbs.isEmpty else { fail("components <bottle> <verb...>") }
        exit(try WindowsSetup.installComponents(verbs, into: bottle(name), output: .inherit))

    case "-h", "--help", "help":
        print(usage)

    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
