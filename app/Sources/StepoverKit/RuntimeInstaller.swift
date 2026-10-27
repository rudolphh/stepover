import CryptoKit
import Foundation

/// The Wine runtime is too big for the app download (about 1 GB unpacked), so the app carries a
/// manifest and fetches the runtime once: Stepover.app/Contents/Resources/runtime.json, or the file
/// named by STEPOVER_RUNTIME_MANIFEST. STEPOVER_RUNTIME_URL overrides the download location.
public struct RuntimeManifest: Codable, Sendable {
    public var name: String      // folder name inside the archive and in Paths.runtimes, e.g. "cx26.3"
    public var url: String       // .tar.xz holding <name>/
    public var sha256: String
    public var size: Int64       // bytes, for progress and the download prompt
    public var summary: String?

    public static func bundled() -> RuntimeManifest? {
        let env = ProcessInfo.processInfo.environment
        let url: URL?
        if let path = env["STEPOVER_RUNTIME_MANIFEST"], !path.isEmpty { url = URL(fileURLWithPath: path) }
        else { url = Paths.appBundle?.url(forResource: "runtime", withExtension: "json") }
        guard let url, let data = try? Data(contentsOf: url),
              var manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return nil }
        if let override = env["STEPOVER_RUNTIME_URL"], !override.isEmpty { manifest.url = override }
        return manifest
    }

    /// Installed and complete (has bin/wine)?
    public var isInstalled: Bool { Runtime.installed().contains { $0.name == name } }

    /// Installed from this exact download? Runtimes record the manifest they came from; one with no
    /// record (installed by 0.1.1 or earlier) or a different checksum needs an update.
    public var isCurrent: Bool {
        Runtime.installed().first { $0.name == name }.map(matches) ?? false
    }

    public func matches(_ runtime: Runtime) -> Bool {
        guard let data = try? Data(contentsOf: runtime.url.appendingPathComponent(RuntimeInstaller.recordName)),
              let recorded = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return false }
        return recorded.sha256.lowercased() == sha256.lowercased()
    }
}

public enum RuntimeInstaller {
    /// The manifest a runtime was installed from, kept inside it (see RuntimeManifest.isCurrent).
    static let recordName = ".stepover-manifest.json"

    static func record(_ manifest: RuntimeManifest, in runtime: Runtime) throws {
        try JSONEncoder().encode(manifest).write(to: runtime.url.appendingPathComponent(recordName))
    }

    /// Downloads (or copies, for file:// URLs and plain paths), verifies and unpacks a runtime.
    /// `progress` gets values from 0 to 1 while downloading. Replacing a runtime under running
    /// Wine processes could crash them, so this refuses while any bottle is running, both before
    /// the download (quick answer) and right before the swap (a game may have started meanwhile).
    public static func install(_ manifest: RuntimeManifest, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Runtime {
        let fm = FileManager.default
        try ensureNothingRunning(manifest)
        let work = Paths.root.appendingPathComponent(".download")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("\(manifest.name).tar.xz")
        try? fm.removeItem(at: archive)

        let source = manifest.url.contains("://") ? URL(string: manifest.url)! : URL(fileURLWithPath: manifest.url)
        if source.isFileURL {
            try fm.copyItem(at: source, to: archive)
        } else {
            try await download(source, to: archive, expected: manifest.size, progress: progress)
        }
        progress?(1)

        guard let digest = sha256(of: archive), digest == manifest.sha256.lowercased() else {
            try? fm.removeItem(at: archive)
            throw StepoverError.message("the runtime download did not match its checksum; try again")
        }
        try fm.createDirectory(at: Paths.runtimes, withIntermediateDirectories: true)
        let staging = Paths.runtimes.appendingPathComponent(".unpack-\(manifest.name)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", staging.path]
        try tar.run(); tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw StepoverError.message("unpacking the runtime failed (tar exit \(tar.terminationStatus))") }

        let unpacked = staging.appendingPathComponent(manifest.name)
        let dest = Paths.runtimes.appendingPathComponent(manifest.name)
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/wine").path) else {
            throw StepoverError.message("the runtime archive has no \(manifest.name)/bin/wine")
        }
        try ensureNothingRunning(manifest)
        if fm.fileExists(atPath: dest.path) {
            let old = Paths.runtimes.appendingPathComponent("\(manifest.name).old")
            try? fm.removeItem(at: old)
            try fm.moveItem(at: dest, to: old)
        }
        try fm.moveItem(at: unpacked, to: dest)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: archive)
        // Anything that arrived with a quarantine flag would make Gatekeeper stop Wine's binaries.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-drs", "com.apple.quarantine", dest.path]
        try? xattr.run(); xattr.waitUntilExit()
        try? record(manifest, in: Runtime(url: dest))  // without it the app only offers the update again
        return Runtime(url: dest)
    }

    static func ensureNothingRunning(_ manifest: RuntimeManifest) throws {
        if manifest.isInstalled, let busy = Bottle.all().first(where: \.isRunning) {
            throw StepoverError.message("quit everything running in \(busy.name) first; the runtime can't be replaced while it's in use")
        }
    }

    static func download(_ url: URL, to file: URL, expected: Int64, progress: (@Sendable (Double) -> Void)?) async throws {
        let delegate = DownloadDelegate(destination: file, expected: expected, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Streams to a temporary file (no whole-file buffering) and reports progress as bytes arrive.
    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL, expected: Int64, progress: (@Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?  // touched only on the session's serial queue

        init(destination: URL, expected: Int64, progress: (@Sendable (Double) -> Void)?) {
            self.destination = destination; self.expected = expected; self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
            let size = total > 0 ? total : expected
            if size > 0 { progress?(min(Double(written) / Double(size), 0.99)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw StepoverError.message("downloading the runtime failed: HTTP \(http.statusCode)")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)  // the temp file vanishes after return
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation?.resume(throwing: error); continuation = nil }
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
