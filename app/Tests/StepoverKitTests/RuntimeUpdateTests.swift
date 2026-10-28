import XCTest
@testable import StepoverKit

final class RuntimeUpdateTests: XCTestCase {
    private func manifest(_ name: String, status: RuntimeStatus? = .current, minApp: String? = nil,
                          url: String = "https://example.com/x.tar.xz", sha256: String = String(repeating: "a", count: 64),
                          size: Int64 = 100) -> RuntimeManifest {
        var m = RuntimeManifest(name: name, url: url, sha256: sha256, size: size, summary: nil)
        m.status = status
        m.minApp = minApp
        return m
    }

    func testSupportsAppVersion() {
        let needs030 = manifest("cx26.4", minApp: "0.3.0")
        XCTAssertFalse(needs030.supports(appVersion: "0.2.2"))
        XCTAssertTrue(needs030.supports(appVersion: "0.3.0"))
        XCTAssertTrue(needs030.supports(appVersion: "0.10.0"))
        XCTAssertTrue(needs030.supports(appVersion: nil))          // a dev build
        XCTAssertTrue(manifest("cx26.4").supports(appVersion: "0.1.0"))
    }

    func testNeededBytes() {
        XCTAssertEqual(manifest("cx26.3", size: 289_986_340).neededBytes, 1_986_802_612)
    }

    func testOfferedSkipsInstalledPulledAndTooNew() {
        let index = RuntimeIndex(runtimes: [manifest("cx26.3", status: .available), manifest("cx26.4")])
        XCTAssertEqual(RuntimeInstaller.offered(index: index, installed: ["cx26.3"], appVersion: "0.3.0")?.name, "cx26.4")
        XCTAssertNil(RuntimeInstaller.offered(index: index, installed: ["cx26.3", "cx26.4"], appVersion: "0.3.0"))
        let pulled = RuntimeIndex(runtimes: [manifest("cx26.3", status: .available), manifest("cx26.4", status: .pulled)])
        XCTAssertNil(RuntimeInstaller.offered(index: pulled, installed: ["cx26.3"], appVersion: "0.3.0"))
        let tooNew = RuntimeIndex(runtimes: [manifest("cx26.4", minApp: "9.0.0")])
        XCTAssertNil(RuntimeInstaller.offered(index: tooNew, installed: ["cx26.3"], appVersion: "0.3.0"))
    }

    func testFailedInstallLeavesRuntimesAlone() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("runtimes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let runtimes = dir.appendingPathComponent("Runtimes")
        try fm.createDirectory(at: runtimes.appendingPathComponent("cx26.3/bin"), withIntermediateDirectories: true)
        let wine = runtimes.appendingPathComponent("cx26.3/bin/wine")
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let archive = dir.appendingPathComponent("cx26.4.tar.xz")
        try Data("x".utf8).write(to: archive)

        do {
            _ = try await RuntimeInstaller.install(manifest("cx26.4", url: archive.path, size: 1), into: runtimes)
            XCTFail("a download that doesn't match its checksum must not install")
        } catch {}
        let left = try fm.contentsOfDirectory(atPath: runtimes.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(left, ["cx26.3"])
        XCTAssertTrue(fm.isExecutableFile(atPath: wine.path))
    }
}
