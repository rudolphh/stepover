import XCTest
@testable import StepoverKit

final class InstallQueueTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUp() {
        dir = fm.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir.appendingPathComponent("Downloads/Tiny Game"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: dir) }

    private var source: URL { dir.appendingPathComponent("Downloads/Tiny Game") }

    private func job(_ name: String, _ stage: InstallStage, added: Double = 0, bottle: String? = nil, source: String? = nil) -> InstallJob {
        InstallJob(source: source ?? "/Users/x/Downloads/\(name)", name: name, bottle: bottle, stage: stage, added: Date(timeIntervalSince1970: added))
    }

    func testSameSourceOnce() throws {
        var queue = InstallQueue()
        let first = queue.add(source: source, name: "Tiny Game", entryID: nil, steam: nil, copiedGame: false)
        let again = queue.add(source: source, name: "Tiny Game", entryID: nil, steam: nil, copiedGame: false)
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let throughLink = queue.add(source: link, name: "Tiny Game", entryID: nil, steam: nil, copiedGame: false)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(throughLink.id, first.id)
        queue.jobs[0].stage = .failed(.damaged)    // a failed one doesn't hold the folder: dropping it again is a new job
        _ = queue.add(source: source, name: "Tiny Game", entryID: nil, steam: nil, copiedGame: false)
        XCTAssertEqual(queue.jobs.count, 2)
    }

    func testSavedAndLoaded() throws {
        var queue = InstallQueue()
        _ = queue.add(source: source, name: "Tiny Game", entryID: "steam:9", steam: 9, copiedGame: true)
        let file = dir.appendingPathComponent("installs.json")
        try queue.save(to: file)
        XCTAssertEqual(InstallQueue.load(from: file).jobs, queue.jobs)
        XCTAssertEqual(InstallQueue.load(from: dir.appendingPathComponent("missing.json")).jobs, [])
    }

    func testNextIsOneAtATime() {
        var queue = InstallQueue(jobs: [job("A", .waiting, added: 1), job("B", .waiting, added: 2)])
        XCTAssertEqual(queue.next()?.name, "A")
        queue.jobs[0].stage = .installing(written: 0)
        XCTAssertNil(queue.next())
        queue.jobs[0].stage = .done(addOnFailed: nil)
        XCTAssertEqual(queue.next()?.name, "B")
    }

    func testInterruptedAfterACrash() {
        var gone = job("A", .installing(written: 5))
        gone.owner = 111
        var cli = job("B", .copying(done: 1, total: 2))
        cli.owner = 222
        var queue = InstallQueue(jobs: [gone, cli, job("C", .waiting)])
        queue.markInterrupted(alive: { $0 == 222 })
        XCTAssertEqual(queue.jobs.map(\.stage), [.failed(.interrupted), .copying(done: 1, total: 2), .waiting])
    }

    private func tiles(_ programs: [Program], installs: [InstallJob], played: [String] = []) -> [LibraryGame] {
        let bottles = Dictionary(grouping: programs, by: { $0.name }).map { name, programs in
            (bottle: Bottle(url: dir.appendingPathComponent("Bottles/\(name)")), config: BottleConfig(programs: programs))
        }
        let recent = played.enumerated().map { RecentGames.Entry(bottle: $1, program: $1, played: Date(timeIntervalSince1970: Double(100 - $0))) }
        return Library.games(bottles: bottles, steamApps: { _ in [] }, index: GameIndex(GamesList(format: 1, generated: "", credits: [], games: [])),
                             recent: recent, installs: installs)
    }

    func testHalfMadeBottleHasNoPlayTile() {
        let tiny = Program(name: "Tiny Game", exe: #"C:\Games\Tiny Game\TinyGame.exe"#)
        let found = tiles([tiny], installs: [job("Tiny Game", .addingComponents, bottle: "Tiny Game")])
        XCTAssertEqual(found.count, 1)
        if case .install = found.first?.kind {} else { XCTFail("an install tile") }
        let ready = tiles([tiny], installs: [job("Tiny Game", .done(addOnFailed: nil), bottle: "Tiny Game")])
        if case .program = ready.first?.kind {} else { XCTFail("the game's own tile once done") }
        XCTAssertEqual(ready.count, 1)
    }

    func testInstallTilesFirst() {
        let found = tiles([Program(name: "Old", exe: #"C:\Old.exe"#), Program(name: "New", exe: #"C:\New.exe"#)],
                          installs: [job("First Drop", .waiting, added: 1), job("Second Drop", .failed(.damaged), added: 2)],
                          played: ["New", "Old"])
        XCTAssertEqual(found.map(\.name), ["Second Drop", "First Drop", "New", "Old"])
    }

    func testTrashOffer() {
        var done = job("Tiny Game", .done(addOnFailed: nil))
        done.playedSeconds = 599
        var queue = InstallQueue(jobs: [done])
        XCTAssertFalse(Afterwards.shouldOffer(done, in: queue, exists: true, local: true))
        done.playedSeconds = 600
        queue.jobs = [done]
        XCTAssertTrue(Afterwards.shouldOffer(done, in: queue, exists: true, local: true))
        XCTAssertFalse(Afterwards.shouldOffer(done, in: queue, exists: false, local: true))
        XCTAssertFalse(Afterwards.shouldOffer(done, in: queue, exists: true, local: false))
        var kept = done
        kept.trashOffer = .kept
        XCTAssertFalse(Afterwards.shouldOffer(kept, in: queue, exists: true, local: true))
        queue.jobs = [done, job("Tiny Game", .waiting, source: done.source)]
        XCTAssertFalse(Afterwards.shouldOffer(done, in: queue, exists: true, local: true))
    }

    func testTrashText() {
        var installer = job("Tiny Game", .done(addOnFailed: nil))
        XCTAssertEqual(Afterwards.text(installer, size: 32_000_000_000), "Move the installer to the Trash (frees 32 GB)")
        installer.copiedGame = true
        XCTAssertEqual(Afterwards.text(installer, size: 32_000_000_000), "Move the original folder to the Trash (frees 32 GB)")
    }

    func testCouchOnInstallTiles() {
        XCTAssertEqual(Couch.installAction(.failed(.damaged), button: .a), .tryAgain)
        XCTAssertEqual(Couch.installAction(.failed(.damaged), button: .b), .removeInstall)
        XCTAssertEqual(Couch.installAction(.confirm, button: .a), .installAnyway)
        XCTAssertEqual(Couch.installAction(.alreadyInLibrary("x"), button: .a), .playExisting("x"))
        XCTAssertEqual(Couch.installAction(.installing(written: 0), button: .a), CouchAction.none)
        XCTAssertEqual(Couch.installAction(.installing(written: 0), button: .b), CouchAction.none)
    }
}
