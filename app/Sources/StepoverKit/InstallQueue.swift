import Foundation

/// What happens to the dropped folder once its game has had a good run (spec D13).
public enum TrashOffer: String, Codable, Sendable { case pending, kept, trashed, none }

/// One dropped item on its way to a Play button.
public struct InstallJob: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var source: String            // the dropped item's path, symlinks resolved
    public var name: String
    public var entryID: String?
    public var steam: Int?
    public var bottle: String?           // the bottle's folder name, once made
    public var stage: InstallStage
    public var owner: Int32?             // the process running it (the app or `stepover add`)
    public var added: Date
    public var copiedGame: Bool          // an installed game's folder, copied in (not an installer)
    public var playedSeconds: Double     // for the Trash offer
    public var trashOffer: TrashOffer

    public init(id: String = UUID().uuidString, source: String, name: String, entryID: String? = nil, steam: Int? = nil,
                bottle: String? = nil, stage: InstallStage = .waiting, owner: Int32? = nil, added: Date = Date(),
                copiedGame: Bool = false, playedSeconds: Double = 0, trashOffer: TrashOffer = .pending) {
        self.id = id; self.source = source; self.name = name; self.entryID = entryID; self.steam = steam; self.bottle = bottle
        self.stage = stage; self.owner = owner; self.added = added; self.copiedGame = copiedGame
        self.playedSeconds = playedSeconds; self.trashOffer = trashOffer
    }

    public var isDone: Bool { if case .done = stage { return true } else { return false } }
    public var isFailed: Bool { if case .failed = stage { return true } else { return false } }
}

/// Dropped games, installed one at a time (spec D10), kept in `<STEPOVER_HOME>/installs.json` so the app and
/// `stepover add` show the same tiles and an interrupted install is known after a restart.
public struct InstallQueue: Codable, Sendable {
    public var jobs: [InstallJob]

    public init(jobs: [InstallJob] = []) { self.jobs = jobs }

    public static var file: URL { Paths.root.appendingPathComponent("installs.json") }

    public static func load(from file: URL = file) -> InstallQueue {
        guard let data = try? Data(contentsOf: file) else { return InstallQueue() }
        return (try? JSONDecoder().decode(InstallQueue.self, from: data)) ?? InstallQueue()
    }

    public func save(to file: URL = file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// Changes one job in the file and saves it (a no-op when it's gone).
    public static func update(_ id: String, file: URL = file, _ change: (inout InstallJob) -> Void) {
        var queue = load(from: file)
        guard let i = queue.jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&queue.jobs[i])
        try? queue.save(to: file)
    }

    /// A new waiting job, or the job that already holds this folder (dropped twice, or through a link). A failed or
    /// finished job doesn't hold it: dropping it again starts over.
    public mutating func add(source: URL, name: String, entryID: String?, steam: Int?, copiedGame: Bool) -> InstallJob {
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        if let held = jobs.first(where: { $0.source == path && !$0.isDone && !$0.isFailed }) { return held }
        let job = InstallJob(source: path, name: name, entryID: entryID, steam: steam, copiedGame: copiedGame)
        jobs.append(job)
        return job
    }

    /// The first waiting job, when nothing is installing.
    public func next() -> InstallJob? {
        jobs.contains { $0.stage.isActive } ? nil : jobs.first { $0.stage == .waiting }
    }

    /// Installs whose process is gone (Stepover quit or crashed) become Interrupted, with Try Again.
    public mutating func markInterrupted(alive: (Int32) -> Bool) {
        for i in jobs.indices where jobs[i].stage.isActive && !(jobs[i].owner.map(alive) ?? false) {
            jobs[i].stage = .failed(.interrupted)
        }
    }
}

/// The offer to move the dropped folder to the Trash once the game has had a good run (spec D13).
public enum Afterwards {
    public static let goodRun = 600.0

    /// Done, still pending, played at least `goodRun`, the folder still there on a volume with a Trash, and no
    /// other waiting or installing job using it.
    public static func shouldOffer(_ job: InstallJob, in queue: InstallQueue, exists: Bool, local: Bool) -> Bool {
        guard job.isDone, job.trashOffer == .pending, job.playedSeconds >= goodRun, exists, local else { return false }
        return !queue.jobs.contains { $0.id != job.id && $0.source == job.source && ($0.stage == .waiting || $0.stage.isActive) }
    }

    public static func text(_ job: InstallJob, size: Int64) -> String {
        (job.copiedGame ? "Move the original folder to the Trash" : "Move the installer to the Trash")
            + " (frees \(InstallStage.gigabytes(size)))"
    }
}
