import AppKit
import Foundation
import GameController
import ServiceManagement
import StepoverKit

/// App state: bottles, their stepover.json, and what is running. Wine work runs off the main thread.
@MainActor
final class Store: ObservableObject {
    @Published var bottles: [Bottle] = []
    @Published var selection: String?
    @Published var configs: [String: BottleConfig] = [:]
    @Published var running: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var creating: [String] = []        // New Bottle names still being made (~15 s)
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

    // MARK: Library
    /// The Library's tiles, rebuilt by reload() and when a newer games list arrives.
    @Published var library: [LibraryGame] = []
    @Published var hidden = Set(LibraryState.load().hidden)
    @Published var showHidden = false
    /// The bottle pages instead of the Library. Remembered only when chosen from the View menu or the Library
    /// button: a tile's Settings opens them for now without changing what the app opens on.
    @Published var showBottles = UserDefaults.standard.bool(forKey: "showBottles")
    /// View > Look Up Unknown Games on Steam (on unless switched off).
    @Published var lookUpUnknown = UserDefaults.standard.object(forKey: "lookUpUnknownGames") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lookUpUnknown, forKey: "lookUpUnknownGames"); if lookUpUnknown { lookUpUnknownGames() } }
    }
    /// Cover art by Steam app id, filled in as downloads land.
    @Published var art: [Int: NSImage] = [:]
    /// Each cover's average color, for the hero's tint (worked out once, when the cover lands).
    var tint: [Int: NSColor] = [:]
    /// Couch mode's look per Steam app id: the game's key art, its logo (light ones only: a dark logo would vanish
    /// on the dark backdrop, so the title is typed instead) and what Steam says about it.
    @Published var keyArt: [Int: NSImage] = [:]
    @Published var logo: [Int: NSImage] = [:]
    @Published var about: [Int: GameAbout] = [:]
    private var lookRequested: Set<Int> = []
    private var checkedStrayPaused = false
    /// The first connected game controller's name, nil when none.
    @Published var controllerName: String?
    /// The first runtime download failed; the toolbar offers Retry instead of an alert.
    @Published var runtimeFailed = false
    // MARK: Couch mode
    /// The Library full screen, driven by a controller (spec: 2026-10-28-couch-mode-design.md).
    @Published var couchMode = false
    /// The library game that's running (checked every 2 s while couch mode is on).
    @Published var runningGame: LibraryGame?
    /// A game that just ended while couch mode was on: couch mode comes back with it selected (C6).
    @Published var endedGame: LibraryGame?
    /// A game started a moment ago that isn't running yet: couch mode says so and A waits (C7). Cleared when it
    /// runs, when starting it fails, or after a minute.
    @Published var starting: LibraryGame?
    /// Resume and Quit Game over a running game, from the controller (C5).
    private(set) lazy var inGame = InGamePanel(store: self)
    /// Open in couch mode when a controller is connected at launch (on unless switched off).
    var openInCouchMode: Bool { UserDefaults.standard.object(forKey: "openInCouchMode") as? Bool ?? true }
    private let launched = Date()
    var gamesList: GamesList
    var gameIndex: GameIndex
    private var artRequested: Set<Int> = []
    /// Installed games the list doesn't know, looked up once on Steam's store from this Mac (LearnedGames).
    var learned = LearnedGames.load()
    private var lookingUp = false
    var lookupStopped = false   // Steam couldn't be reached this launch
    var gamesCredits: [String] { gamesList.credits }
    // MARK: Adding games from an installer or folder (spec: 2026-10-29-add-game-from-folder-design.md)
    /// The shared queue (installs.json): games on their way in, and finished ones still owed the Trash offer.
    @Published var installs: [InstallJob] = []
    /// The job this process is installing now (one at a time, D10).
    var installingJob: String?
    /// The Trash offer by bottle name, once a game from a dropped folder has had a good run (D13).
    @Published var trashOffers: [String: String] = [:]
    /// The tile of the game that just finished installing: the Library and couch mode select it ("come back to a Play button").
    @Published var justAdded: String?
    /// When each item was last handed to add(): the Dock's open can arrive twice (window and app delegate).
    var recentlyAdded: [String: Date] = [:]
    var playSavedAt = Date()

    init() {
        let list = GamesList.load()
        gamesList = list
        gameIndex = GameIndex(list)
        loadInstalls()
        reload()
        Task { _ = await FixLibrary.update(); refreshFixes() }  // quietly; offline just keeps the last copy
        refreshIndex()
        if GamesList.needsRefresh() {   // at most once a day; offline keeps the cached or bundled list
            Task {
                if await GamesList.fetch() {
                    gamesList = GamesList.load()
                    gameIndex = GameIndex(gamesList)
                    rebuildLibrary()
                }
            }
        }
        watchControllers()
        startFirstDownload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    var selected: Bottle? { bottles.first { $0.id == selection } }

    /// Each bottle's pinned runtime and the one it uses now (a running bottle: the one its Wine started on),
    /// for the Wine Runtimes window.
    var runtimeUsers: [(name: String, pinned: String?, resolved: String?)] {
        bottles.map { bottle in
            let config = config(bottle)
            return (bottle.name, config.runtime,
                    RuntimeCatalog.inUse(resolved: bottle.runtime(config)?.name, running: running.contains(bottle.id),
                                         lastRuntime: bottle.lastRuntime))
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

    /// Fetches the runtime list from GitHub (at launch, on Reload and when Wine Runtimes opens); offline keeps the cache.
    func refreshIndex() {
        Task {
            if await RuntimeIndex.fetch() {
                index = RuntimeIndex.load()
                startFirstDownload()   // the list can arrive after launch with the runtime to get
            }
        }
    }

    /// A first launch starts the one download games need by itself (spec: Wine runtime, in plain words).
    private func startFirstDownload() {
        if !runtimeReady && runtimeProgress == nil && !runtimeFailed && manifest != nil { installRuntime() }
    }

    /// The runtime a first install downloads: one this app can use.
    var manifest: RuntimeManifest? { RuntimeInstaller.firstInstall(index: index, appVersion: Paths.appVersion) }

    /// A new runtime to offer, never while a game is running.
    var runtimeUpdate: RuntimeManifest? {
        guard runtimeReady, running.isEmpty else { return nil }
        return RuntimeInstaller.offered(index: index, installed: Runtime.installed().map(\.name), appVersion: Paths.appVersion)
    }

    func reload() {
        // a game still on its way in has no bottle page (and so no Play there, or in the Dock menu) until it's ready,
        // nor does a bottle still being made
        let unfinished = InstallQueue(jobs: installs).unfinishedBottles
        bottles = Bottle.all().filter { !unfinished.contains($0.name) && !creating.contains($0.name) }
        configs = Dictionary(uniqueKeysWithValues: bottles.map { ($0.id, $0.loadConfig()) })
        display = Dictionary(uniqueKeysWithValues: bottles.map { ($0.id, ($0.highResolution, $0.dpi)) })
        index = RuntimeIndex.load()
        if selection == nil || !bottles.contains(where: { $0.id == selection }) { selection = bottles.first?.id }
        refreshRunning()
        refreshFixes()
        rebuildLibrary()
    }

    func rebuildLibrary() {
        library = Library.games(bottles: bottles.map { (bottle: $0, config: config($0)) },
                                steamApps: { SteamLibrary.apps(in: $0) }, index: gameIndex, recent: RecentGames.load(),
                                learned: learned.index, installs: installs)
        loadArt()
        loadCouchLook()
        lookUpUnknownGames()
    }

    /// Asks Steam's store about installed games the list doesn't know (View > Look Up Unknown Games on Steam):
    /// one request every 1.5 s, at most 20 games a launch, each result saved and shown as it lands. When Steam
    /// can't be reached it stops and doesn't try again until the next launch.
    private func lookUpUnknownGames() {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let wanted = Library.lookups(library, learned: learned, today: today)
        guard lookUpUnknown, !lookingUp, !lookupStopped, !wanted.isEmpty else { return }
        lookingUp = true
        var record = learned
        Task {
            let outcome = await record.lookUp(wanted, today: today,
                                              pause: { try? await Task.sleep(nanoseconds: UInt64(LearnedGames.steamSpacing * 1e9)) },
                                              progress: { latest in Task { @MainActor in self.applyLearned(latest) } })
            if outcome == .stopped { lookupStopped = true }
            lookingUp = false
        }
    }

    func applyLearned(_ latest: LearnedGames) {
        learned = latest
        try? latest.save()
        rebuildLibrary()
    }

    /// Covers read (or downloaded, four at a time) and their tints worked out off the main thread; each is shown
    /// as it lands.
    private func loadArt() {
        let wanted = Set(library.compactMap(\.steamAppID)).subtracting(artRequested).sorted()
        artRequested.formUnion(wanted)
        guard !wanted.isEmpty else { return }
        Task.detached {
            for start in stride(from: 0, to: wanted.count, by: 4) {
                let chunk = wanted[start..<min(start + 4, wanted.count)]
                let landed = await withTaskGroup(of: (Int, Data?).self) { group -> [(Int, Data)] in
                    for id in chunk {
                        group.addTask { (id, await GameArt.fetch(id).flatMap { try? Data(contentsOf: $0) }) }
                    }
                    var out: [(Int, Data)] = []
                    for await (id, data) in group { if let data { out.append((id, data)) } }
                    return out
                }
                let tinted = landed.map { ($0.0, $0.1, CoverTint.average($0.1)) }
                await MainActor.run {
                    for (id, data, tint) in tinted {
                        guard let image = NSImage(data: data) else { continue }
                        if let tint { self.tint[id] = NSColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1) }
                        self.art[id] = image
                    }
                }
            }
        }
    }

    /// Each Steam game's key art, logo and blurb for couch mode, fetched once (then read from Art on disk).
    private func loadCouchLook() {
        let wanted = Set(library.compactMap(\.steamAppID)).subtracting(lookRequested).sorted()
        lookRequested.formUnion(wanted)
        guard !wanted.isEmpty else { return }
        Task.detached {
            for id in wanted {
                let hero = await GameArt.fetch(id, kind: .hero).flatMap { try? Data(contentsOf: $0) }
                let logo = await GameArt.fetch(id, kind: .logo).flatMap { try? Data(contentsOf: $0) }
                let lightLogo = logo.flatMap { LogoTone.isDark($0) == false ? $0 : nil }
                let asked = ["\(id)-about.json", "\(id)-about.none"].contains {
                    FileManager.default.fileExists(atPath: GameArt.folder.appendingPathComponent($0).path)
                }
                let about = await GameAbout.fetch(id)
                if !asked { try? await Task.sleep(for: .seconds(1.5)) }   // Steam limits appdetails, as LearnedGames does
                await MainActor.run {
                    if let hero, let image = NSImage(data: hero) { self.keyArt[id] = image }
                    if let lightLogo, let image = NSImage(data: lightLogo) { self.logo[id] = image }
                    if let about { self.about[id] = about }
                }
            }
        }
    }

    func playGame(_ game: LibraryGame) {
        guard runtimeReady, game.install == nil else { return }   // also covers double-click while the first download runs
        starting = game
        work(nil, "Starting \(game.name)", {
            do { try Launcher.run(game.launch, in: game.bottle) } catch {
                Task { @MainActor in self.starting = nil }
                throw error
            }
        }, then: { self.rebuildLibrary() })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if self?.starting?.id == game.id { self?.starting = nil }
        }
        showWhenItOpens(game)
    }

    /// Brings a game Stepover just started in front once it has a window: macOS leaves one that opens on another
    /// desktop, or behind couch mode's full screen, out of sight. Gives up after two minutes.
    private func showWhenItOpens(_ game: LibraryGame) {
        // off the main thread: listing every window takes ~30 ms
        Task.detached { [weak self] in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard self != nil else { return }
                let pids = Couch.processes(of: game, in: RunningPrograms.processes()).map(\.pid)
                if !pids.isEmpty, Couch.hasGameWindow(pids: pids, windows: Store.windows()) {
                    await MainActor.run { DockMenu.bringToFront(pids) }
                    return
                }
            }
        }
    }

    nonisolated private static func windows() -> [GameWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue, let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            return GameWindow(pid: pid, layer: layer, width: width, height: height)
        }
    }

    func setHidden(_ game: LibraryGame, _ hide: Bool) {
        if hide { hidden.insert(game.id) } else { hidden.remove(game.id) }
        do { try LibraryState(hidden: hidden.sorted()).save() } catch { alert = error.localizedDescription }
    }

    /// View > Library or Bottles, and the Library button on the bottle pages: remembered for next launch.
    func setView(bottles: Bool) {
        showBottles = bottles
        UserDefaults.standard.set(bottles, forKey: "showBottles")
    }

    /// Settings on a tile: the game's bottle page, this time only.
    func openSettings(_ game: LibraryGame) {
        guard FileManager.default.fileExists(atPath: game.bottle.url.path) else { return }
        selection = game.bottle.id
        showBottles = true
    }

    private func watchControllers() {
        updateController()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateController() }
            }
        }
    }

    private func updateController() {
        controllerName = GCController.controllers().first.map { $0.vendorName ?? "Game controller" }
        // a controller already on as Stepover opens means the couch (C1); the setting turns that off
        if controllerName != nil, openInCouchMode, Date().timeIntervalSince(launched) < 8, !couchMode { couchMode = true }
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

    /// Continues a game a previous Stepover left paused (it crashed or was force quit with the in-game panel up).
    private func continueStrayPaused(_ processes: [RunningPrograms.Process]) {
        for pid in Couch.strayPaused(library, processes: processes, isStopped: RunningPrograms.isStopped, ours: inGame.paused) {
            kill(pid, SIGCONT)
        }
    }

    func refreshRunning() {
        if !checkedStrayPaused, !library.isEmpty {   // once at launch, whatever mode; then with each running-game check
            checkedStrayPaused = true
            continueStrayPaused(RunningPrograms.processes())
        }
        let now = Set(bottles.filter(\.isRunning).map(\.id))
        if now != running { running = now }
        trackPlay()
        // the running game matters to couch mode and, with a controller on, to the in-game panel
        if couchMode || controllerName != nil || runningGame != nil || starting != nil { updateRunningGame() }
    }

    func updateRunningGame() {
        let processes = RunningPrograms.processes()
        continueStrayPaused(processes)
        let current = Couch.running(library, processes: processes)
        if let previous = runningGame, current == nil, couchMode { comeBack(after: previous) }
        if current?.id != runningGame?.id { runningGame = current }
        if let current, current.id == starting?.id { starting = nil }
        inGame.watch(current)
    }

    /// Couch mode in front again after a game (C6), with that game selected; reopens the window if it was closed.
    func comeBack(after game: LibraryGame) {
        endedGame = game   // Stepover comes back in the mode it was in (Quit Game from the panel works in the Library too)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            // opening a running app is a reopen, which SwiftUI answers with a new window when none is open
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.activate()
    }

    /// Resume: the running game back in front (as the Dock menu's Bring to Front does).
    func resume(_ game: LibraryGame) {
        DockMenu.bringToFront(Couch.processes(of: game, in: RunningPrograms.processes()).map(\.pid))
    }

    /// Quit Game: just this game (a Steam game's own processes, else its bottle), then `then`.
    func quitGame(_ game: LibraryGame, then: (() -> Void)? = nil) {
        let plan = Couch.quitPlan(game, processes: RunningPrograms.processes())
        if case .processes(let pids) = plan { Launcher.appendLog(game.bottle, "quitting \(game.name): ending \(pids)") }
        else { Launcher.appendLog(game.bottle, "quitting \(game.name): stopping its bottle") }
        switch plan {
        case .processes(let pids):
            Task {
                await ProcessEnd.end(pids)   // continued first: the in-game panel may have them paused
                updateRunningGame()
                then?()
            }
        case .bottle(let bottle):
            work(bottle, "Quitting \(game.name)", { try Launcher.stop(bottle) }, then: { self.updateRunningGame(); then?() })
        }
    }

    /// Makes `screen` the main display (where games go full screen), the way System Settings > Displays does.
    func makeMainDisplay(_ screen: NSScreen) {
        guard let target = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        let active = Array(ids.prefix(Int(count)))
        let origins = DisplayLayout.originsMakingMain(CGDisplayBounds(target), all: active.map(CGDisplayBounds))
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (id, origin) in zip(active, origins) { CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y)) }
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            alert = "That screen couldn't be made the main display; use System Settings > Displays."
        }
    }

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert = "Open at Login couldn't be changed: \(error.localizedDescription)"
        }
        objectWillChange.send()
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
        let first = !runtimeReady
        runtimeProgress = 0
        runtimeFailed = false
        Task {
            do {
                _ = try await RuntimeInstaller.install(target) { fraction in
                    Task { @MainActor in self.runtimeProgress = fraction }
                }
                runtimeReady = true
                startNextInstall()   // games dropped before the runtime arrived
            } catch {
                // the first download says so in the Library's toolbar, with Retry; later ones keep the alert
                if first { runtimeFailed = true } else { alert = "Installing the Wine runtime failed: \(error.localizedDescription)" }
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
        creating.append(name)
        work(nil, "Creating \(name)") { try Importer.create(name) } then: {
            self.creating.removeAll { $0 == name }
            self.reload()
            self.selection = self.bottles.first { $0.name == name }?.id
        }
    }
}
