import Foundation

/// Creating bottles: new empty ones, or instant APFS copies of CrossOver bottles.
public enum Importer {
    /// CrossOver bottles that exist, with whether a Stepover bottle of that name exists already.
    public static func crossOverBottles() -> [(name: String, imported: Bool)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Paths.crossOverBottles.path)) ?? []
        return names.filter { fm.fileExists(atPath: Paths.crossOverBottles.appendingPathComponent("\($0)/cxbottle.conf").path) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, Bottle.named($0) != nil) }
    }

    /// Copies a CrossOver bottle (APFS clone: no extra disk space until files change) and turns its
    /// cxbottle.conf settings and Start Menu shortcuts into a stepover.json. CrossOver's bottle is not touched.
    @discardableResult
    public static func importCrossOver(_ name: String, as newName: String? = nil) throws -> Bottle {
        let source = Paths.crossOverBottles.appendingPathComponent(name)
        let dest = Paths.bottles.appendingPathComponent(newName ?? name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("cxbottle.conf").path) else {
            throw StepoverError.message("no CrossOver bottle named \(name)")
        }
        guard !fm.fileExists(atPath: dest.path) else { throw StepoverError.message("\(dest.path) already exists") }
        guard !Bottle(url: source).isRunning else {
            throw StepoverError.message("CrossOver's \(name) bottle is running; quit the game first so its registry is saved")
        }
        try fm.createDirectory(at: Paths.bottles, withIntermediateDirectories: true)

        // cp -c clones on APFS; -R keeps symlinks (Documents -> ~/Documents, z: -> /) as symlinks.
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rc", source.path, dest.path]
        try cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0 else { throw StepoverError.message("copying \(name) failed (cp exit \(cp.terminationStatus))") }

        let bottle = Bottle(url: dest)
        var config = BottleConfig(origin: "CrossOver bottle \(name), copied \(ISO8601DateFormatter().string(from: Date()))")
        let conf = (try? String(contentsOf: source.appendingPathComponent("cxbottle.conf"), encoding: .utf8)) ?? ""
        var env = crossOverEnvironment(conf)
        config.graphics = env.removeValue(forKey: "CX_GRAPHICS_BACKEND").flatMap { Backend(rawValue: $0.lowercased()) } ?? .d3dmetal
        env.removeValue(forKey: "WINEESYNC")           // CrossOver 26's Wine has no ESync; it never did anything
        if env["WINEMSYNC"] == nil { env["WINEMSYNC"] = "0" }  // absent means off in CrossOver; keep it that way
        config.env = env
        config.programs = programs(in: bottle)
        config.setupInf = upToDateInf(source: Bottle(url: source), runtime: Runtime.resolve(nil))
        try bottle.save(config)
        return bottle
    }

    /// The runtime's wine.inf hash when the CrossOver bottle is set up with CrossOver's wine.inf and that
    /// file is identical to the runtime's; then the copy needs no setup redo (see SetupStamp).
    static func upToDateInf(source: Bottle, runtime: Runtime?) -> String? {
        let crossOverInf = Paths.crossOverApp.appendingPathComponent("Contents/SharedSupport/CrossOver/share/wine/wine.inf")
        guard let runtime, let ours = SetupStamp.sha256(of: runtime.wineInf),
              SetupStamp.sha256(of: crossOverInf) == ours,
              let stamp = SetupStamp.read(source), stamp == SetupStamp.mtime(of: crossOverInf) else { return nil }
        return ours
    }

    /// [EnvironmentVariables] of a cxbottle.conf
    static func crossOverEnvironment(_ conf: String) -> [String: String] {
        var env: [String: String] = [:]
        var inSection = false
        for raw in conf.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[EnvironmentVariables]"; continue }
            guard inSection, line.hasPrefix("\""),
                  let match = line.range(of: #"^"([^"]+)"\s*=\s*"(.*)"$"#, options: .regularExpression) else { continue }
            let parts = line[match].split(separator: "=", maxSplits: 1)
            let key = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            env[key] = value
        }
        return env
    }

    /// Programs from the bottle's Start Menu and public desktop shortcuts, uninstallers left out.
    public static func programs(in bottle: Bottle) -> [Program] {
        let roots = ["ProgramData/Microsoft/Windows/Start Menu/Programs", "users/Public/Desktop"]
            .map { bottle.cDrive.appendingPathComponent($0) }
        var seen = Set<String>()
        var out: [Program] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
                let name = url.deletingPathExtension().lastPathComponent
                guard !name.lowercased().contains("uninstall"), let link = ShellLink(url: url), let target = link.target,
                      target.lowercased().hasSuffix(".exe"), !seen.contains(target.lowercased()) else { continue }
                seen.insert(target.lowercased())
                var program = Program(name: name.replacingOccurrences(of: "Play ", with: ""), exe: target)
                if let args = link.arguments, !args.isEmpty { program.args = args.split(separator: " ").map(String.init) }
                if let dir = link.workdir, !dir.isEmpty { program.workdir = dir }
                if let exe = WindowsPath.toMac(target, bottle: bottle) {
                    let pick = GraphicsPicker.pick(exe: exe)
                    program.graphics = pick.backend
                    program.env = pick.env
                }
                out.append(program)
            }
        }
        return out
    }

    /// A new, empty 64-bit bottle (Windows 10, MSync on, D3DMetal by default).
    @discardableResult
    public static func create(_ name: String) throws -> Bottle {
        let dest = Paths.bottles.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw StepoverError.message("\(name) already exists") }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let bottle = Bottle(url: dest)
        try bottle.save(BottleConfig(graphics: .d3dmetal, env: ["WINEMSYNC": "1"], origin: "created by Stepover"))
        let status = try Launcher.wine(["wineboot", "--init"], bottle: bottle, wait: true)
        guard status == 0 else { throw StepoverError.message("wineboot exited with \(status); see \(bottle.logURL.path)") }
        return bottle
    }
}
