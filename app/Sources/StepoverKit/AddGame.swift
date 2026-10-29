import Foundation

public struct AddGameError: Error, Equatable, LocalizedError {
    public var failure: InstallFailure
    public init(_ failure: InstallFailure) { self.failure = failure }
    public var errorDescription: String? { failure.text }
}

/// What each added game's bottle keeps about how its install went, in `stepover-install.json` (spec: Project 2 hooks).
/// It names the job that made the bottle, so only that job can delete it.
public struct InstallOutcome: Codable, Equatable, Sendable {
    public var job: String
    public var stage = "started"
    public var installers: [String] = []   // kind labels, "(unarc)" when unarc.dll appeared; never the installer's source
    public var exitStatus: Int32?
    public var fixes: [String] = []
    public var components: [String] = []
    public var seconds: Double = 0
    public var logTail: [String] = []      // the bottle log's last lines, the dropped folder as "<folder>", home as "~"

    public init(job: String) { self.job = job }

    public static func file(_ bottle: Bottle) -> URL { bottle.url.appendingPathComponent("stepover-install.json") }

    public static func load(_ bottle: Bottle) -> InstallOutcome? {
        (try? Data(contentsOf: file(bottle))).flatMap { try? JSONDecoder().decode(InstallOutcome.self, from: $0) }
    }

    public func save(to bottle: Bottle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.file(bottle), options: .atomic)
    }

    /// The dropped folder becomes "<folder>" and the home folder "~", in Mac and Windows (Z:) spelling.
    public static func redact(_ lines: [String], source: String, home: String) -> [String] {
        func windows(_ path: String) -> String { "Z:" + path.replacingOccurrences(of: "/", with: "\\") }
        let pairs = [(source, "<folder>"), (windows(source), "<folder>"), (home, "~"), (windows(home), "~")]
            .filter { !$0.0.isEmpty && $0.0 != "Z:" }
        return lines.map { line in pairs.reduce(line) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }
    }
}

/// Adding a game from an installer or folder, start to Play (spec: 2026-10-29-add-game-from-folder-design.md).
/// `stepover add` and the app both run it; every decision it makes comes from the tested rules beside it.
public enum AddGame {
    public typealias Report = @Sendable (InstallStage) -> Void

    // MARK: names

    /// Safe as a Mac folder name and a Windows one: characters Windows forbids become " - ".
    static func safe(_ game: String) -> String {
        var name = game.replacingOccurrences(of: #"\s*[<>:"/\\|?*\x00-\x1F]+\s*"#, with: " - ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        return name.isEmpty ? "Game" : name
    }

    /// The new bottle's name: the game's, else "Name 2", "Name 3"…
    public static func bottleName(for game: String, in folder: URL = Paths.bottles) -> String {
        let base = safe(game)
        var name = base, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    public static func installDir(for game: String) -> String { #"C:\Games\"# + safe(game) }

    /// Each argument is passed on its own; Wine quotes one with spaces as a whole, which installers read as one.
    public static func silentArguments(_ kind: InstallerKind, dir: String, log: String) -> [String] {
        switch kind {
        case .inno: return ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/DIR=" + dir, "/LOG=" + log]
        case .nsis: return ["/S", "/D=" + dir]   // /D= last, never quoted (NSIS reads the rest of the line raw)
        case .msi: return ["/qn", "TARGETDIR=" + dir, "INSTALLDIR=" + dir]
        case .other: return []
        }
    }

    /// NSIS's batch line: the installer, quoted, then /S /D=<dir> raw and last. cmd reads `%` everywhere and `^ &` outside
    /// quotes, so those are escaped (`| < >` can't be in a folder name).
    public static func nsisBatchLine(file: String, dir: String) -> String {
        let quoted = file.replacingOccurrences(of: "%", with: "%%")
        let raw = dir.replacingOccurrences(of: "^", with: "^^").replacingOccurrences(of: "&", with: "^&")
            .replacingOccurrences(of: "%", with: "%%")
        return "@\"\(quoted)\" /S /D=\(raw)\r\n"
    }

    /// The batch file in the Windows code page Wine's cmd reads it in; nil when the names can't be written in it.
    public static func nsisBatch(file: String, dir: String) -> Data? {
        nsisBatchLine(file: file, dir: dir).data(using: .windowsCP1252, allowLossyConversion: false)
    }

    /// The folder in plain letters: accents dropped, anything else outside ASCII left out.
    public static func asciiDir(_ dir: String) -> String {
        let folded = dir.applyingTransform(.stripDiacritics, reverse: false) ?? dir
        let ascii = String(String.UnicodeScalarView(folded.unicodeScalars.filter(\.isASCII)))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return ascii.hasSuffix(#"\"#) ? ascii + "Game" : ascii
    }

    /// The message of the last error Inno Setup logged with its message boxes suppressed (the last line of that box).
    public static func innoError(fromLog log: String) -> String? {
        let lines = log.components(separatedBy: .newlines)
        guard let start = lines.lastIndex(where: { $0.contains("suppressed message box") }) else { return nil }
        let stamped = #"^\d{4}-\d{2}-\d{2} "#
        let box = lines[(start + 1)...].prefix { $0.range(of: stamped, options: .regularExpression) == nil }
        return box.map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    // MARK: recognizing

    /// Names to try, best first: a dropped folder's name, its base installer's file name and product name; for a dropped
    /// file, its own name and product name, then its folder's. Matched against the games list, then (when `lookUp`) one
    /// Steam store lookup by the first name, recorded in `learned` (spec D2).
    public static func recognize(_ item: URL, plan: DropPlan, index: GameIndex, learned: inout LearnedGames, lookUp: Bool,
                                 today: String) async -> Recognized {
        var names: [String] = []
        let base: URL? = { if case .install(let installers) = plan { return installers.first?.url } else { return nil } }()
        if GameFolder.isDirectory(item) {
            names = [item.lastPathComponent] + [base?.lastPathComponent].compactMap { $0 }
            if let product = base.flatMap({ PEFile(url: $0)?.productName }) { names.append(product) }
        } else {
            names = [item.lastPathComponent] + [PEFile(url: item)?.productName].compactMap { $0 } + [item.deletingLastPathComponent().lastPathComponent]
        }
        let candidates = names.map(FolderName.clean).filter { name in
            let lower = name.lowercased()
            return !lower.hasPrefix("setup") && !lower.hasPrefix("install") && !["downloads", "desktop", "documents"].contains(lower)
        }
        let found = Recognize.game(candidates: candidates, index: index, learned: learned.index)
        guard found.entry == nil, lookUp, let first = candidates.first else { return found }
        _ = await learned.lookUp([(name: first, appID: nil)], today: today, limit: 1, pause: {}, progress: { _ in })
        try? learned.save()
        return Recognize.game(candidates: candidates, index: index, learned: learned.index)
    }

    // MARK: the bottle

    /// Windows 10 64-bit, MSync on, High Resolution Mode at DPI 96, personal folders inside, Wine's menu builder off
    /// (spec D4). The bottle's stepover-install.json names `job` from the start, so a failed job can delete it.
    public static func makeBottle(named name: String, job: String) throws -> Bottle {
        let path = Paths.bottles.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw StepoverError.message("\(name) already exists") }
        do {
            let bottle = try Importer.create(name, extraEnv: ["WINEDLLOVERRIDES": "winemenubuilder.exe=d"])
            try InstallOutcome(job: job).save(to: bottle)
            var config = bottle.loadConfig()
            config.origin = "added by Stepover from an installer or folder"
            try bottle.save(config, fixes: [])
            try BottleSetup.keepPersonalFoldersInside(bottle)
            try Launcher.setDisplay(highResolution: true, dpi: 96, bottle: bottle)
            var patch = RegistryPatch()
            patch.set(#"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#, "winemenubuilder.exe", .string(""))
            try Launcher.importRegistry(patch, into: bottle)
            return bottle
        } catch {
            try? FileManager.default.removeItem(at: path)   // the name was free, so this is the half-made bottle
            throw error
        }
    }

    /// Deletes a bottle only when its stepover-install.json names this job.
    public static func discard(bottleNamed name: String, job: String, in folder: URL = Paths.bottles) throws {
        let bottle = Bottle(url: folder.appendingPathComponent(name))
        guard InstallOutcome.load(bottle)?.job == job else {
            throw StepoverError.message("\(name) wasn't made by this install, so it stays")
        }
        if bottle.isRunning { try? Launcher.stop(bottle) }
        try FileManager.default.removeItem(at: bottle.url)
    }

    // MARK: the whole job

    /// Mounts an .iso first; runs the installers (or copies the game's folder) while watching them; finds the game; sets
    /// its graphics, MetalFX and components; applies its fixes; writes InstallOutcome. Keeps the Mac from idle sleep
    /// meanwhile. Throws AddGameError.
    public static func run(_ plan: DropPlan, source: URL, game: String, into bottle: Bottle, job: String, knownExes: [String],
                           report: @escaping Report) throws -> (program: Program, addOnFailed: String?) {
        let started = Date()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                            reason: "Installing \(game)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var outcome = InstallOutcome.load(bottle) ?? InstallOutcome(job: job)
        func finish(_ stage: String) {
            outcome.stage = stage
            outcome.seconds = Date().timeIntervalSince(started)
            let log = (try? String(contentsOf: bottle.logURL, encoding: .utf8)) ?? ""
            outcome.logTail = InstallOutcome.redact(Array(log.components(separatedBy: .newlines).suffix(50)), source: source.path,
                                                    home: FileManager.default.homeDirectoryForCurrentUser.path)
            try? outcome.save(to: bottle)
        }
        do {
            // a folder still being copied in (no partial-download names to tell) waits until it has settled
            while GameFolder.isChanging(source) {
                guard FileManager.default.fileExists(atPath: source.path) else { throw AddGameError(.folderGone) }
                report(.gettingReady)
                Thread.sleep(forTimeInterval: 5)
            }
            let result = try install(plan, source: source, game: game, bottle: bottle, knownExes: knownExes, outcome: &outcome, report: report)
            finish("ready")
            return result
        } catch let error as AddGameError {
            finish(error.failure.text)
            throw error
        } catch {
            finish("error: \(error.localizedDescription)")
            throw error
        }
    }

    static func install(_ plan: DropPlan, source: URL, game: String, bottle: Bottle, knownExes: [String],
                        outcome: inout InstallOutcome, report: @escaping Report) throws -> (program: Program, addOnFailed: String?) {
        let dir = installDir(for: game)
        guard let dirMac = WindowsPath.toMac(dir, bottle: bottle) else { throw AddGameError(.nothing) }
        let shortcutsBefore = Set(Importer.programs(in: bottle).map { $0.exe.lowercased() })
        let foldersBefore = Set(programFolders(bottle).map(\.path))
        var addOnFailed: String?

        switch plan {
        case .diskImage(let image):
            let mount = try attach(image)
            defer { detach(mount) }
            return try install(GameFolder.plan(for: mount), source: source, game: game, bottle: bottle, knownExes: knownExes,
                               outcome: &outcome, report: report)
        case .install(let installers):
            for installer in installers {
                Launcher.appendLog(bottle, "running the \(installer.role.rawValue) \(installer.kind.label)")
                do {
                    let result = try runInstaller(installer, bottle: bottle, dir: dir, dirMac: dirMac, source: source, report: report)
                    outcome.installers.append(installer.kind.label + (result.unarc ? " (unarc)" : ""))
                    if installer.role == .base { outcome.exitStatus = result.status }
                    let ok = installer.kind == .other || result.status == 0 || (installer.kind == .msi && result.status == 3010)
                    if !ok {
                        let damaged = (ChecksumCheck.damaged(in: installer.url.deletingLastPathComponent()) ?? 0) > 0
                        throw AddGameError(damaged ? .damaged : .installerError(result.error))
                    }
                } catch let error as AddGameError where installer.role != .base && error.failure != .folderGone {
                    addOnFailed = addOnFailed ?? FolderName.clean(installer.url.lastPathComponent)
                }
            }
        case .installedGame(let folder):
            try copyGame(folder, to: dirMac, source: source, report: report)
            outcome.installers.append("installed game folder")
        case .several, .nothing: throw AddGameError(.nothing)
        case .archive: throw AddGameError(.archive)
        case .stillDownloading: throw AddGameError(.stillDownloading)
        }

        report(.findingGame)
        guard let found = findGame(game, bottle: bottle, dirMac: dirMac, shortcutsBefore: shortcutsBefore,
                                   foldersBefore: foldersBefore, knownExes: knownExes) else { throw AddGameError(.noGame) }
        var config = bottle.loadConfig()
        config.programs = [found.program]
        try bottle.save(config)
        Launcher.appendLog(bottle, "the game is \(found.program.exe)")

        report(.addingComponents)
        let scan = NeededComponents.scan(found.folder)
        let verbs = NeededComponents.verbs(imports: scan.imports, shipped: scan.shipped)
        if !verbs.isEmpty {
            let status = (try? WindowsSetup.installComponents(verbs, into: bottle)) ?? -1
            if status != 0 {
                var latest = bottle.loadConfig()
                latest.failedComponents += verbs.filter { !latest.failedComponents.contains($0) }
                try bottle.save(latest)
                Launcher.appendLog(bottle, "couldn't install \(verbs.joined(separator: " ")); the game is ready without them")
            }
        }
        Launcher.applyFixes(bottle)
        let final = bottle.loadConfig()
        outcome.components = verbs
        outcome.fixes = Launcher.matchedFixes(bottle, config: final).map(\.fix.name)
        return (found.program, addOnFailed)
    }

    // MARK: running one installer

    static let installEnv = ["WINEDLLOVERRIDES": "winebrowser.exe=d"]   // no installer opens a page on the Mac (D5)

    /// Runs one installer unattended and watches it (InstallWatch) until it and everything it started have ended.
    static func runInstaller(_ installer: Installer, bottle: Bottle, dir: String, dirMac: URL, source: URL,
                             report: @escaping Report) throws -> (status: Int32, error: String?, unarc: Bool) {
        let file = WindowsPath.toWindows(installer.url, bottle: bottle)
        let logWin = #"C:\windows\temp\stepover-inno-"# + UUID().uuidString.prefix(8) + ".log"
        var args: [String]
        switch installer.kind {
        case .inno: args = [file] + silentArguments(.inno, dir: dir, log: logWin)
        case .msi: args = ["msiexec", "/i", file] + silentArguments(.msi, dir: dir, log: logWin)
        case .other: args = [file]
        case .nsis:
            // NSIS reads /D= raw, and Wine would quote it; a batch file passes the line as written.
            let temp = bottle.cDrive.appendingPathComponent("windows/temp")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            var batch = nsisBatch(file: file, dir: dir)
            if batch == nil {   // a name Wine's cmd can't read: the game goes to a plain-letters folder (found as a new folder)
                batch = nsisBatch(file: file, dir: asciiDir(dir))
                Launcher.appendLog(bottle, "the NSIS installer gets \(asciiDir(dir)): cmd can't read \(dir)")
            }
            try (batch ?? Data(nsisBatchLine(file: file, dir: dir).utf8))
                .write(to: temp.appendingPathComponent("stepover-install.bat"), options: .atomic)
            args = ["cmd", "/c", #"C:\windows\temp\stepover-install.bat"#]
        }
        let workdir = installer.url.deletingLastPathComponent()
        let visible = installer.kind == .other
        let pid = try Launcher.wine(args, bottle: bottle, workdir: workdir, extraEnv: installEnv, wait: false)
        report(visible ? .needsYou : .installing(written: 0))

        var watch = InstallWatch(kind: installer.kind, visible: visible)
        let started = Date()
        var status: Int32?, copy: (pid: Int32, original: Int32)?, copyStatus: Int32?
        var written: Int64 = 0, free = freeSpace(), sizedAt = -10.0, unarc = false
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            if status == nil { status = reap(pid) }
            if let c = copy, copyStatus == nil, let s = reap(c.pid) {
                copyStatus = s
                kill(c.original, SIGCONT); kill(c.original, SIGKILL)
            }
            let processes = installProcesses(RunningPrograms.processes(), bottle: bottle, installerFolder: workdir)
            let now = Date().timeIntervalSince(started)
            if now - sizedAt >= 10 {
                sizedAt = now
                written = size(of: dirMac)
                free = freeSpace()
                unarc = unarc || usesUnarc(bottle)
                if !visible, !watch.isPaused { report(.installing(written: written)) }
            }
            let sample = InstallSample(time: now, processes: processes, cpuSeconds: processes.reduce(0) { $0 + RunningPrograms.cpuSeconds($1.pid) },
                                       written: written, free: free, sourceExists: FileManager.default.fileExists(atPath: source.path))
            for action in watch.step(sample) {
                switch action {
                case .end(let pids):
                    pids.forEach { kill($0, SIGKILL) }
                    let names = processes.filter { pids.contains($0.pid) }.map(\.exeName)
                    Launcher.appendLog(bottle, "ended steps that hang under Wine: \(names.joined(separator: ", "))")
                case .largeAddressFix(let original, let path):
                    if let started = try startLargeAddressCopy(original: original, path: path, bottle: bottle, workdir: workdir,
                                                               log: copyLog(logWin)) {
                        copy = (started, original)
                    }
                case .pause(let pids):
                    pids.forEach { kill($0, SIGSTOP) }
                    Launcher.appendLog(bottle, "paused: the disk is nearly full")
                    report(.paused)
                case .resume(let pids):
                    pids.forEach { kill($0, SIGCONT) }
                    Launcher.appendLog(bottle, "carrying on: there is room again")
                    report(.installing(written: written))
                case .stuck:
                    Launcher.appendLog(bottle, "the installer stopped responding; ending it")
                    try? Launcher.stop(bottle)
                    throw AddGameError(.stoppedResponding)
                case .sourceGone:
                    Launcher.appendLog(bottle, "the installer's folder went away; ending the install")
                    try? Launcher.stop(bottle)
                    throw AddGameError(.folderGone)
                }
            }
            if status != nil, copy == nil || copyStatus != nil, processes.allSatisfy(\.isSystem) { break }
        }
        try Launcher.waitUntilIdle(bottle)
        let final = copyStatus ?? status ?? -1
        Launcher.appendLog(bottle, "the \(installer.kind.label) exited with \(final)")
        let log = WindowsPath.toMac(copy == nil ? logWin : copyLog(logWin), bottle: bottle)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return (final, installer.kind == .inno ? innoError(fromLog: log) : nil, unarc)
    }

    /// Spec Appendix A: pause this setup.tmp, and run a copy of it without the large-address-aware flag, with the loader's
    /// own arguments (/SL5=…). Only when the flag is set (it is what freezes unarc), or with
    /// STEPOVER_LARGE_ADDRESS_FIX=always (the scripted checks, whose test installer lacks it). Returns the copy's pid.
    static func startLargeAddressCopy(original: Int32, path: String, bottle: Bottle, workdir: URL, log: String) throws -> Int32? {
        let always = ProcessInfo.processInfo.environment["STEPOVER_LARGE_ADDRESS_FIX"] == "always"
        guard let mac = WindowsPath.toMac(path, bottle: bottle), let pe = PEFile(url: mac), pe.isLargeAddressAware || always else { return nil }
        kill(original, SIGSTOP)
        let args = RunningPrograms.arguments(original)
        guard args.contains(where: { $0.uppercased().hasPrefix("/SL5=") }), let data = try? Data(contentsOf: mac),
              let cleared = PEFile.clearingLargeAddressAware(data) else {
            kill(original, SIGCONT)
            return nil
        }
        let copyMac = mac.deletingLastPathComponent().appendingPathComponent("setup-stepover.tmp")
        try cleared.write(to: copyMac)
        let pid = try Launcher.wine([WindowsPath.toWindows(copyMac, bottle: bottle)] + copyArguments(args, log: log), bottle: bottle,
                                    workdir: workdir, extraEnv: installEnv, wait: false)
        Launcher.appendLog(bottle, "applied the large-address fix to setup.tmp")
        return pid
    }

    /// The paused original keeps its log open, so the copy writes its own.
    static func copyLog(_ log: String) -> String { String(log.dropLast(".log".count)) + "-copy.log" }

    /// The copy's arguments: the original's (the loader's /SL5=… and the silent ones) without its own path, with its own log.
    static func copyArguments(_ original: [String], log: String) -> [String] {
        original.dropFirst().map { $0.uppercased().hasPrefix("/LOG=") ? "/LOG=" + log : $0 }
    }

    /// The install's processes: the bottle's, and the installer's own, which run with the installer's folder (outside the
    /// bottle) as their working directory. Paths are compared as given and resolved, with and without /private.
    static func installProcesses(_ all: [RunningPrograms.Process], bottle: Bottle, installerFolder: URL) -> [RunningPrograms.Process] {
        func forms(_ url: URL) -> Set<String> {
            var out = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
            for path in out { out.insert(path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path) }
            return Set(out.map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        }
        let roots = forms(bottle.url).union(forms(installerFolder))
        return all.filter { process in roots.contains { (process.cwd + "/").hasPrefix($0) } }
    }

    /// The exit status of a child that has ended, else nil.
    static func reap(_ pid: Int32) -> Int32? {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        return r < 0 ? -1 : nil
    }

    /// Inno Setup unpacked unarc into its temporary folder.
    static func usesUnarc(_ bottle: Bottle) -> Bool {
        let temp = bottle.cDrive.appendingPathComponent("users/crossover/AppData/Local/Temp")
        return GameFolder.files(in: temp, levels: 2).contains { ["unarc.dll", "isdone.dll"].contains($0.lastPathComponent.lowercased()) }
    }

    // MARK: an installed game's folder

    /// Copies an installed game into the bottle (an instant clone on the same disk), with progress and the disk floor.
    static func copyGame(_ folder: URL, to dest: URL, source: URL, report: Report) throws {
        let total = size(of: folder)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rc", folder.path, dest.path]
        try cp.run()
        var paused = false
        report(.copying(done: 0, total: total))
        while cp.isRunning {
            Thread.sleep(forTimeInterval: 1)
            guard FileManager.default.fileExists(atPath: source.path) else {
                cp.terminate()
                throw AddGameError(.folderGone)
            }
            let free = freeSpace()
            if !paused, free < InstallWatch.floor { paused = true; kill(cp.processIdentifier, SIGSTOP); report(.paused) }
            if paused, free >= InstallWatch.resumeAt { paused = false; kill(cp.processIdentifier, SIGCONT) }
            if !paused { report(.copying(done: size(of: dest), total: total)) }
        }
        guard cp.terminationStatus == 0 else { throw AddGameError(.installerError("Copying the game didn't finish")) }
    }

    // MARK: finding the game

    static func programFolders(_ bottle: Bottle) -> [URL] {
        ["Program Files", "Program Files (x86)", "Games"].flatMap { GameFolder.children(of: bottle.cDrive.appendingPathComponent($0)) }
            .filter(GameFolder.isDirectory)
    }

    /// The game's program (spec D7): in the install folder, else in the folders of new shortcuts, else in folders that
    /// are new under Program Files (an installer that ignored the folder it was given).
    static func findGame(_ game: String, bottle: Bottle, dirMac: URL, shortcutsBefore: Set<String>, foldersBefore: Set<String>,
                         knownExes: [String]) -> (program: Program, folder: URL)? {
        let shortcuts = Importer.programs(in: bottle).filter { !shortcutsBefore.contains($0.exe.lowercased()) }
        var folders = [dirMac]
        folders += shortcuts.compactMap { WindowsPath.toMac($0.exe, bottle: bottle)?.deletingLastPathComponent() }
        folders += programFolders(bottle).filter { !foldersBefore.contains($0.path) }
        var seen = Set<String>()
        for folder in folders where GameFolder.isDirectory(folder) && seen.insert(folder.standardizedFileURL.path).inserted {
            let ranked = GameFinder.rank(GameFinder.candidates(in: folder, shortcuts: shortcuts.map(\.exe)), gameName: game, knownExes: knownExes)
            guard let best = ranked.first else { continue }
            let exeMac = folder.appendingPathComponent(best.path)
            let exe = WindowsPath.toWindows(exeMac, bottle: bottle)
            var program = shortcuts.first { $0.exe.lowercased() == exe.lowercased() } ?? Program(name: game, exe: exe)
            program.name = game
            let pick = GraphicsPicker.pick(exe: exeMac)
            program.graphics = pick.backend
            program.env = pick.env
            if pick.backend == .d3dmetal, NeededComponents.shipsDLSS(NeededComponents.scan(folder).shipped) {
                program.env["D3DM_ENABLE_METALFX"] = "1"
            }
            return (program, folder)
        }
        return nil
    }

    // MARK: disk

    /// Bytes in a folder and everything in it.
    public static func size(of folder: URL) -> Int64 {
        GameFolder.files(in: folder, levels: .max).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func freeSpace() -> Int64 {
        let folder = FileManager.default.fileExists(atPath: Paths.bottles.path) ? Paths.bottles : Paths.root.deletingLastPathComponent()
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: disk images

    /// Mounts an .iso read-only, hidden from Finder; returns where.
    static func attach(_ image: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("stepover-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image.path]
        hdiutil.standardOutput = FileHandle.nullDevice
        try hdiutil.run(); hdiutil.waitUntilExit()
        guard hdiutil.terminationStatus == 0 else { throw AddGameError(.nothing) }
        return mountPoint
    }

    static func detach(_ mountPoint: URL) {
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["detach", "-quiet", mountPoint.path]
        try? hdiutil.run(); hdiutil.waitUntilExit()
        try? FileManager.default.removeItem(at: mountPoint)
    }
}
