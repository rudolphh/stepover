import AppKit
import Foundation
import StepoverKit

/// Adding games from an installer or folder (spec: docs/superpowers/specs/2026-10-29-add-game-from-folder-design.md):
/// the shared queue in installs.json, one install at a time, the tiles' buttons, and the Trash offer.
extension Store {
    /// At launch: installs whose process is gone (Stepover quit or crashed) become Interrupted, with Try Again.
    func loadInstalls() {
        var queue = InstallQueue.load()
        queue.markInterrupted(alive: { pid in
            kill(pid, 0) == 0 && (RunningPrograms.arguments(pid).first?.lowercased().contains("stepover") ?? false)
        })
        try? queue.save()
        installs = queue.jobs
        refreshTrashOffers()
        startNextInstall()
    }

    /// Re-reads installs.json (`stepover add` may have changed it), applies `change`, saves it, and redraws the Library.
    func mutateInstalls(_ change: (inout InstallQueue) -> Void) {
        var queue = InstallQueue.load()
        change(&queue)
        try? queue.save()
        installs = queue.jobs
        rebuildLibrary()
    }

    func setStage(_ id: String, _ stage: InstallStage) {
        mutateInstalls { queue in
            guard let i = queue.jobs.firstIndex(where: { $0.id == id }) else { return }
            if stage.isActive, queue.jobs[i].isDone || queue.jobs[i].isFailed { return }   // a late report never undoes the end
            queue.jobs[i].stage = stage
        }
    }

    /// Dropped on the window or the Dock icon, chosen in File > Add Game from Installer or Folder…, or picked in couch
    /// mode: each item becomes a tile at once, then installs in turn.
    func add(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            let plan = GameFolder.plan(for: url)
            let failure: InstallFailure?
            switch plan {
            case .several(let folders): add(folders); continue
            case .archive: failure = .archive
            case .stillDownloading: failure = .stillDownloading
            case .nothing: failure = .nothing
            default: failure = nil
            }
            if let failure {
                mutateInstalls { queue in
                    let job = queue.add(source: url, name: FolderName.clean(url.lastPathComponent), entryID: nil, steam: nil, copiedGame: false)
                    if let i = queue.jobs.firstIndex(where: { $0.id == job.id }), job.stage == .waiting, job.bottle == nil {
                        queue.jobs[i].stage = .failed(failure)
                    }
                }
                continue
            }
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            let index = gameIndex, lookUp = lookUpUnknown && !lookupStopped
            let copied: Bool = { if case .installedGame = plan { return true } else { return false } }()
            Task {
                var learned = self.learned
                let found = await AddGame.recognize(url, plan: plan, index: index, learned: &learned, lookUp: lookUp, today: today)
                if learned.entries != self.learned.entries || learned.misses != self.learned.misses { applyLearned(learned) }
                let existing = Recognize.existing(found, in: library)
                mutateInstalls { queue in
                    let job = queue.add(source: url, name: found.name, entryID: found.entry?.id, steam: found.entry?.steam, copiedGame: copied)
                    guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }), job.stage == .waiting, job.owner == nil,
                          job.bottle == nil else { return }
                    if let existing { queue.jobs[i].stage = .alreadyInLibrary(existing.id) }
                    else if Recognize.needsConfirmation(found.entry) { queue.jobs[i].stage = .confirm }
                }
                startNextInstall()
            }
        }
    }

    /// File > Add Game from Installer or Folder…
    func chooseToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.message = "Choose a game's installer or folder"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// The next waiting game, when nothing is installing (here or in `stepover add`) and the runtime is in.
    func startNextInstall() {
        guard runtimeReady, installingJob == nil, let job = InstallQueue.load().next() else { return }
        let name = AddGame.bottleName(for: job.name)
        installingJob = job.id
        mutateInstalls { queue in
            guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            queue.jobs[i].owner = getpid()
            queue.jobs[i].bottle = name
            queue.jobs[i].stage = .gettingReady
        }
        let source = URL(fileURLWithPath: job.source)
        let known = job.entryID.flatMap { id in gamesList.games.first { $0.id == id } }?.exes ?? []
        Task.detached {
            let result = Result { () throws -> (program: Program, addOnFailed: String?) in
                guard FileManager.default.fileExists(atPath: source.path) else { throw AddGameError(.folderGone) }
                let bottle = try AddGame.makeBottle(named: name, job: job.id)
                return try AddGame.run(GameFolder.plan(for: source), source: source, game: job.name, into: bottle, job: job.id,
                                       knownExes: known, report: { stage in Task { @MainActor in self.setStage(job.id, stage) } })
            }
            await MainActor.run {
                self.installingJob = nil
                switch result {
                case .success(let done): self.setStage(job.id, .done(addOnFailed: done.addOnFailed))
                case .failure(let error):
                    self.setStage(job.id, .failed((error as? AddGameError)?.failure ?? .installerError(error.localizedDescription)))
                }
                self.reload()
                self.startNextInstall()
            }
        }
    }

    // MARK: the tile's buttons

    /// Starts over in a fresh bottle (D9).
    func tryAgain(_ job: InstallJob) {
        if let bottle = job.bottle { try? AddGame.discard(bottleNamed: bottle, job: job.id) }
        mutateInstalls { queue in
            guard let i = queue.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            queue.jobs[i].stage = .waiting
            queue.jobs[i].bottle = nil
            queue.jobs[i].owner = nil
        }
        startNextInstall()
    }

    /// Removes the tile and the bottle this install made (nothing of the player's is in it).
    func removeInstall(_ job: InstallJob) {
        if let bottle = job.bottle { try? AddGame.discard(bottleNamed: bottle, job: job.id) }
        mutateInstalls { queue in queue.jobs.removeAll { $0.id == job.id } }
        reload()
    }

    /// Install Anyway (the firm no, D3) and Install Again (already in the Library: a second copy).
    func installAnyway(_ job: InstallJob) {
        mutateInstalls { queue in
            if let i = queue.jobs.firstIndex(where: { $0.id == job.id }) { queue.jobs[i].stage = .waiting }
        }
        startNextInstall()
    }

    func playExisting(_ id: String) {
        if let game = library.first(where: { $0.id == id }) { playGame(game) }
    }

    /// Installed, but no program was clearly the game: the player picks it (D9).
    func chooseGame(_ job: InstallJob) {
        guard let name = job.bottle, let bottle = Bottle.named(name) else { return }
        addProgram(to: bottle)
        guard !config(bottle).programs.isEmpty else { return }
        setStage(job.id, .done(addOnFailed: nil))
        reload()
    }

    /// Details: the install's log.
    func showInstallLog(_ job: InstallJob) {
        let log = Paths.logs.appendingPathComponent("\(job.bottle ?? job.name).log")
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
    }

    /// Quitting while a game installs (the player said yes): the install stops and reads Interrupted.
    func stopInstallForQuit() {
        guard let id = installingJob, let job = installs.first(where: { $0.id == id }) else { return }
        if let name = job.bottle { try? Launcher.stop(Bottle(url: Paths.bottles.appendingPathComponent(name))) }
        setStage(id, .failed(.interrupted))
    }

    // MARK: the Trash offer (D13)

    /// Every 2 s with the running check: time played counts for games added from a folder whose offer is pending.
    func trackPlay() {
        let pending = installs.filter { $0.isDone && $0.trashOffer == .pending && $0.bottle != nil }
        guard !pending.isEmpty else { return }
        var crossed = false
        for job in pending where running.contains(Paths.bottles.appendingPathComponent(job.bottle!).path) {
            guard let i = installs.firstIndex(where: { $0.id == job.id }) else { continue }
            let before = installs[i].playedSeconds
            installs[i].playedSeconds += 2
            if before < Afterwards.goodRun, installs[i].playedSeconds >= Afterwards.goodRun { crossed = true }
        }
        guard crossed || Date().timeIntervalSince(playSavedAt) > 30 else { return }
        playSavedAt = Date()
        let played = Dictionary(uniqueKeysWithValues: installs.map { ($0.id, $0.playedSeconds) })
        var queue = InstallQueue.load()
        for i in queue.jobs.indices { if let seconds = played[queue.jobs[i].id] { queue.jobs[i].playedSeconds = max(queue.jobs[i].playedSeconds, seconds) } }
        try? queue.save()
        if crossed { refreshTrashOffers() }
    }

    /// Works out which games get the offer, with the folder's size, off the main thread.
    func refreshTrashOffers() {
        let queue = InstallQueue(jobs: installs)
        Task.detached {
            var offers: [String: String] = [:]
            for job in queue.jobs where job.isDone && job.trashOffer == .pending {
                let url = URL(fileURLWithPath: job.source)
                let exists = FileManager.default.fileExists(atPath: url.path)
                let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false
                guard let bottle = job.bottle, Afterwards.shouldOffer(job, in: queue, exists: exists, local: local) else { continue }
                offers[bottle] = Afterwards.text(job, size: AddGame.size(of: url))
            }
            let found = offers
            await MainActor.run { self.trashOffers = found }
        }
    }

    func moveSourceToTrash(bottle: String) {
        guard let job = installs.first(where: { $0.bottle == bottle && $0.isDone }) else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: job.source), resultingItemURL: nil)
            setTrashOffer(job, .trashed)
        } catch {
            alert = "Couldn't move it to the Trash: \(error.localizedDescription)"
        }
    }

    func keepSource(bottle: String) {
        if let job = installs.first(where: { $0.bottle == bottle && $0.isDone }) { setTrashOffer(job, .kept) }
    }

    private func setTrashOffer(_ job: InstallJob, _ offer: TrashOffer) {
        mutateInstalls { queue in
            if let i = queue.jobs.firstIndex(where: { $0.id == job.id }) { queue.jobs[i].trashOffer = offer }
        }
        if let bottle = job.bottle { trashOffers[bottle] = nil }
    }
}
