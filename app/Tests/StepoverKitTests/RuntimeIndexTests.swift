import XCTest
@testable import StepoverKit

final class RuntimeIndexTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func entry(_ name: String, status: String? = nil, url: String? = nil, note: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["name": name, "url": url ?? "https://example.com/\(name).tar.xz",
                                "sha256": String(repeating: "a", count: 64), "size": 100]
        if let status { e["status"] = status }
        if let note { e["note"] = note }
        return e
    }

    private func json(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["runtimes": entries])
    }

    func testIndexDecodesAndPicksCurrent() {
        let index = RuntimeIndex.decode(json([entry("cx26.3", status: "available"), entry("cx26.4", status: "current")]))
        XCTAssertEqual(index?.current?.name, "cx26.4")
        XCTAssertEqual(index?.runtimes.map(\.name), ["cx26.3", "cx26.4"])
    }

    func testIndexMissingStatusCountsAsCurrent() {
        XCTAssertEqual(RuntimeIndex.decode(json([entry("cx26.3")]))?.current?.name, "cx26.3")
    }

    func testIndexDropsUnsafeEntries() {
        let data = json([entry("../x"), entry("a/b"), entry(""), entry("cx26.4", url: "http://example.com/x.tar.xz"),
                         entry("cx26.5", url: "file:///tmp/cx26.5.tar.xz"), entry("cx26.4-2")])
        XCTAssertEqual(RuntimeIndex.decode(data)?.runtimes.map(\.name), ["cx26.4-2"])
        XCTAssertEqual(RuntimeIndex.decode(data, allowLocal: true)?.runtimes.map(\.name), ["cx26.5", "cx26.4-2"])
    }

    func testIndexDropsMalformedURLs() {
        let data = json([entry("cx26.3", url: "https://exa mple.com/x.tar.xz"), entry("cx26.4", url: "https://[/x"),
                         entry("cx26.5", url: "https:///x.tar.xz"), entry("cx26.6")])
        XCTAssertEqual(RuntimeIndex.decode(data)?.runtimes.map(\.name), ["cx26.6"])
    }

    func testIndexPulledNames() {
        let index = RuntimeIndex.decode(json([entry("cx26.3", status: "current"), entry("cx26.4", status: "pulled", note: "breaks RDR2")]))
        XCTAssertEqual(index?.pulled, ["cx26.4"])
        XCTAssertEqual(index?.current?.name, "cx26.3")
    }

    func testRepositoryIndexFileIsValid() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let index = RuntimeIndex.decode(try Data(contentsOf: repo.appendingPathComponent("runtime/index.json")))
        XCTAssertEqual(index?.current?.name, "cx26.3-2")
        XCTAssertEqual(index?.current?.sha256, "f3c6966d736f6cd81866d99a42fa782b78da2f3b1146bbfefd37f56504dcf71c")
        XCTAssertEqual(index?.current?.compatFormat, 3)
    }

    func testFetchKeepsCacheOnBadData() async throws {
        let cache = dir.appendingPathComponent("runtime-index.json"), bad = dir.appendingPathComponent("bad.json")
        try json([entry("cx26.3")]).write(to: cache)
        try Data("{".utf8).write(to: bad)
        let updated = await RuntimeIndex.fetch(from: bad.path, to: cache)
        XCTAssertFalse(updated)
        XCTAssertEqual(RuntimeIndex.load(cache: cache, bundled: nil).runtimes.map(\.name), ["cx26.3"])
    }

    func testFetchFromUnreachableSourceKeepsCache() async throws {
        let cache = dir.appendingPathComponent("runtime-index.json")
        try json([entry("cx26.3")]).write(to: cache)
        let updated = await RuntimeIndex.fetch(from: "https://127.0.0.1:9/index.json", to: cache)
        XCTAssertFalse(updated)
        XCTAssertEqual(RuntimeIndex.load(cache: cache, bundled: nil).runtimes.map(\.name), ["cx26.3"])
    }

    func testFetchWritesCache() async throws {
        let cache = dir.appendingPathComponent("runtime-index.json"), good = dir.appendingPathComponent("good.json")
        try json([entry("cx26.3", status: "available"), entry("cx26.4", status: "current")]).write(to: good)
        let updated = await RuntimeIndex.fetch(from: good.path, to: cache)
        XCTAssertTrue(updated)
        XCTAssertEqual(RuntimeIndex.load(cache: cache, bundled: nil).current?.name, "cx26.4")
    }
}
