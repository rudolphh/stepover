import AppKit
import StepoverKit
import Foundation

/// App state: bottles, their stepover.json, and what is running. Wine work runs off the main thread.
@MainActor
final class Store: ObservableObject {
    @Published var bottles: [Bottle] = []
    @Published var selection: String?
    @Published var configs: [String: BottleConfig] = [:]
    @Published var running: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var alert: String?
    @Published var display: [String: (highRes: Bool, dpi: Int)] = [:]
    @Published var runtimeReady = !Runtime.installed().isEmpty
    @Published var runtimeProgress: Double?
    @Published var hasCrossOver = !Importer.crossOverBottles().isEmpty
    /// Fixes matching each bottle, including ones turned off there (the toggles show which).
    @Published var fixCandidates: [String: [MatchedFix]] = [:]
    @Published var showFixSources = false
    @Published var showRuntimes = false
    /// Fixes skipped as invalid and flagged items left out, from the last load.
    @Published var fixNotes: [String] = []
    /// The runtime list (cached copy, else the runtime this app was built with); refreshed from GitHub at launch.
    @Published var index = RuntimeIndex.load()
    private var icons: [String: NSImage] = [:]
    private var timer: Timer?

    init() {
        reload()
        Task { _ = await FixLibrary.update(); refreshFixes() }  // quietly; offline just keeps the last copy
        Task { if await RuntimeIndex.fetch() { index = RuntimeIndex.load() } }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    var selected: Bottle? { bottles.first { $0.id == selection } }

    /// Each bottle's pinned runtime and the one it runs on now, for the Wine Runtimes window.
    var runtimeUsers: [(name: String, pinned: String?, resolved: String?)] {
        bottles.map { bottle in
            let config = config(bottle)
            return (bottle.name, config.runtime, bottle.runtime(config)?.name)
        }
    }

    func removeRuntime(_ runtime: Runtime) {
        do { try RuntimeCatalog.remove(runtime, bottles: bottles) } catch { alert = error.localizedDescription }
        reload()
    }

    /// Moves every bottle off a pulled runtime to Newest, forgetting that it ran there (Runtime.choose would
    /// otherwise keep it on the pulled runtime).
    func switchBottles(off runtime: String) {
        for bottle in bottles where config(bottle).runtime == runtime || bottle.runtime(config(bottle))?.name == runtime {
            useNewest(bottle)
        }
        reload()
    }

    /// Sets a bottle to Newest and forgets the runtime it last ran on, so it moves to the newest good runtime
    /// even from a pulled one.
    func useNewest(_ bottle: Bottle) {
        update(bottle) { $0.runtime = nil }
        bottle.lastRuntime = nil
        objectWillChange.send()
    }

    /// The runtime a first install downloads.
    var manifest: RuntimeManifest? { index.current }

    /// A new runtime to offer, never while a game is running.
    var runtimeUpdate: RuntimeManifest? {
        guard runtimeReady, running.isEmpty else { return nil }
        return RuntimeInstaller.offered(index: index, installed: Runtime.installed().map(\.name), appVersion: Paths.appVersion)
    }

    func reload() {
        bottles = Bottle.all()
        configs = Dictionary(uniqueKeysWithValues: bottles.map { ($0.id, $0.loadConfig()) })
        display = Dictionary(uniqueKeysWithValues: bottles.map { ($0.id, ($0.highResolution, $0.dpi)) })
        index = RuntimeIndex.load()
        if selection == nil || !bottles.contains(where: { $0.id == selection }) { selection = bottles.first?.id }
        refreshRunning()
        refreshFixes()
    }

    func refreshFixes() {
        let bottles = self.bottles, configs = self.configs
        Task.detached {
            let loaded = FixLibrary.load()
            let fixes = loaded.fixes, notes = loaded.notes
            var out: [String: [MatchedFix]] = [:]
            for bottle in bottles {
                var config = configs[bottle.id] ?? bottle.loadConfig()
                config.fixes = true
                config.disabledFixes = []
                out[bottle.id] = config.matchedFixes(fixes, programs: Launcher.programNames(bottle, config: config),
                                                     steamApps: SteamLibrary.apps(in: bottle))
            }
            let result = out
            await MainActor.run { self.fixCandidates = result; self.fixNotes = notes }
        }
    }

    func refreshRunning() {
        let now = Set(bottles.filter(\.isRunning).map(\.id))
        if now != running { running = now }
    }

    func config(_ bottle: Bottle) -> BottleConfig { configs[bottle.id] ?? bottle.loadConfig() }

    func update(_ bottle: Bottle, _ change: (inout BottleConfig) -> Void) {
        var config = self.config(bottle)
        change(&config)
        // the fixes already matched for this bottle, so saving doesn't rescan the disk on the main thread
        // (before the first scan finishes, save works them out itself)
        let fixes = fixCandidates[bottle.id].map { config.fixes ? $0.filter { !config.disabledFixes.contains($0.fix.id) } : [] }
        do { try bottle.save(config, fixes: fixes); configs[bottle.id] = config } catch { alert = error.localizedDescription }
    }

    func icon(for program: Program, in bottle: Bottle) -> NSImage? {
        let key = bottle.id + "|" + program.exe
        if let cached = icons[key] { return cached }
        guard let exe = WindowsPath.toMac(program.exe, bottle: bottle), let data = PEFile.icon(for: exe),
              let image = NSImage(data: data) else { return nil }
        icons[key] = image
        return image
    }

    /// Runs blocking Wine work on a background thread; `bottle` is marked busy meanwhile.
    func work(_ bottle: Bottle?, _ label: String, _ job: @escaping @Sendable () throws -> Void, then: (() -> Void)? = nil) {
        if let bottle { busy.insert(bottle.id) }
        Task.detached {
            let failure: String?
            do { try job(); failure = nil } catch { failure = "\(label): \(error.localizedDescription)" }
            await MainActor.run {
                if let bottle { self.busy.remove(bottle.id) }
                if let failure { self.alert = failure }
                then?()
                self.refreshRunning()
            }
        }
    }

    // MARK: actions

    func play(_ program: Program, in bottle: Bottle) {
        work(nil, "Starting \(program.name)") { try Launcher.run(program, in: bottle) }
    }

    func runTool(_ args: [String], in bottle: Bottle) {
        work(nil, args.joined(separator: " ")) { try Launcher.wine(args, bottle: bottle, wait: false) }
    }

    /// Asks for an .exe or .msi in the bottle and runs it.
    func runExe(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.directoryURL = bottle.cDrive
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!, .init(filenameExtension: "msi")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let windows = WindowsPath.toWindows(url, bottle: bottle)
        runTool(url.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", windows] : [windows], in: bottle)
    }

    func stop(_ bottle: Bottle) {
        work(bottle, "Stopping \(bottle.name)") { try Launcher.stop(bottle) }
    }

    func setDisplay(_ bottle: Bottle, highRes: Bool, dpi: Int) {
        display[bottle.id] = (highRes, dpi)
        work(bottle, "Display settings") { try Launcher.setDisplay(highResolution: highRes, dpi: dpi, bottle: bottle) } then: {
            self.display[bottle.id] = (bottle.highResolution, bottle.dpi)
        }
    }

    func makeApp(_ program: Program, in bottle: Bottle) {
        do {
            let app = try MacLauncher.create(for: program, in: bottle)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch { alert = error.localizedDescription }
    }

    func addProgram(to bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.directoryURL = bottle.cDrive
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!]
        panel.message = "Choose the program's .exe inside the bottle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pick = GraphicsPicker.pick(exe: url)
        let program = Program(name: url.deletingPathExtension().lastPathComponent,
                              exe: WindowsPath.toWindows(url, bottle: bottle), graphics: pick.backend, env: pick.env)
        update(bottle) { $0.programs.append(program) }
    }

    func importCrossOver(_ name: String) {
        work(nil, "Importing \(name)") { try Importer.importCrossOver(name) } then: {
            self.reload()
            self.selection = self.bottles.first { $0.name == name }?.id
        }
    }

    func installRuntime() {
        guard let target = runtimeReady ? runtimeUpdate : manifest, runtimeProgress == nil else { return }
        runtimeProgress = 0
        Task {
            do {
                _ = try await RuntimeInstaller.install(target) { fraction in
                    Task { @MainActor in self.runtimeProgress = fraction }
                }
                runtimeReady = true
            } catch {
                alert = "Installing the Wine runtime failed: \(error.localizedDescription)"
            }
            runtimeProgress = nil
            reload()
        }
    }

    func installProgram(into bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!, .init(filenameExtension: "msi")!]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.message = "Choose the Windows installer (setup .exe or .msi)"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        busy.insert(bottle.id)
        Task.detached {
            let result = Result { try WindowsSetup.install(file, into: bottle) }
            await MainActor.run {
                self.busy.remove(bottle.id)
                switch result {
                case .success(let added) where added.isEmpty:
                    self.alert = "The installer finished but made no Start Menu or desktop shortcut. Use Add Program… to pick the game's .exe."
                case .success(let added):
                    self.alert = "Added " + added.map(\.name).joined(separator: ", ") + "."
                case .failure(let error):
                    self.alert = "Installing failed: \(error.localizedDescription)"
                }
                self.configs[bottle.id] = bottle.loadConfig()
            }
        }
    }

    func installComponents(_ verbs: [String], into bottle: Bottle) {
        busy.insert(bottle.id)
        Task.detached {
            let result = Result { try WindowsSetup.installComponents(verbs, into: bottle) }
            await MainActor.run {
                self.busy.remove(bottle.id)
                switch result {
                case .success(0): self.alert = "Installed \(verbs.joined(separator: ", "))."
                case .success(let status): self.alert = "winetricks exited with \(status) for \(verbs.joined(separator: ", ")); see the bottle's log."
                case .failure(let error): self.alert = error.localizedDescription
                }
            }
        }
    }

    // MARK: fixes

    func setFix(_ id: String, on: Bool, in bottle: Bottle) {
        update(bottle) { config in
            config.disabledFixes.removeAll { $0 == id }
            if !on { config.disabledFixes.append(id) }
        }
    }

    func updateFixes() {
        Task {
            let report = await FixLibrary.update()
            alert = "Fix list updated.\n" + report.joined(separator: "\n")
            refreshFixes()
        }
    }

    func openFixesFolder() {
        try? FileManager.default.createDirectory(at: FixLibrary.localFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FixLibrary.localFolder)
    }

    func saveFix(_ program: Program, in bottle: Bottle) {
        do {
            let file = try FixLibrary.saveLocal(FixLibrary.fix(from: program, in: bottle))
            NSWorkspace.shared.activateFileViewerSelecting([file])
            refreshFixes()
        } catch { alert = "Saving the fix failed: \(error.localizedDescription)" }
    }

    func shareFix(_ program: Program, in bottle: Bottle) {
        if let url = FixLibrary.shareURL(for: FixLibrary.fix(from: program, in: bottle)) { NSWorkspace.shared.open(url) }
    }

    func report(_ program: Program, in bottle: Bottle) {
        if let url = FixLibrary.reportURL(program: program, in: bottle) { NSWorkspace.shared.open(url) }
    }

    func openFixGuide() {
        if let url = FixLibrary.guideURL { NSWorkspace.shared.open(url) }
    }

    func openLicenses() {
        if let runtime = Runtime.resolve(nil) { NSWorkspace.shared.open(runtime.url.appendingPathComponent("licenses")) }
        else { alert = "The Wine runtime is not installed yet." }
    }

    func openSource() {
        if let link = Bundle.main.object(forInfoDictionaryKey: "StepoverSourceURL") as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func create(_ name: String) {
        work(nil, "Creating \(name)") { try Importer.create(name) } then: {
            self.reload()
            self.selection = self.bottles.first { $0.name == name }?.id
        }
    }
}
