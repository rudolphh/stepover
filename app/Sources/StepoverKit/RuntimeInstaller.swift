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
    // From the runtime list (runtime/index.json, RuntimeIndex); absent in older manifests.
    public var released: String?
    public var status: RuntimeStatus?
    public var note: String?          // shown to users, for example why a runtime was pulled
    public var minApp: String?        // the oldest Stepover that can use this runtime
    public var compatFormat: Int?     // the stepover-compat.conf format its compat plug-in reads

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

    /// Whether an app of this version can use the runtime (`minApp`); a development build (no version) can use any.
    public func supports(appVersion: String?) -> Bool {
        guard let minApp, let appVersion else { return true }
        return Self.version(appVersion, atLeast: minApp)
    }

    /// Free space a download needs: the archive, the unpacked runtime (about four times the archive) and a margin.
    public var neededBytes: Int64 { size * 5 + 512 * 1_048_576 }

    /// Dot-separated numbers compared in order; anything after a "-" is ignored (0.10.0 is newer than 0.9.1).
    static func version(_ version: String, atLeast minimum: String) -> Bool {
        func numbers(_ s: String) -> [Int] { (s.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 } }
        let a = numbers(version), b = numbers(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
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

    /// The runtime to offer: the list's current one, when this app can use it and it isn't installed. A new
    /// name installs next to the others, so nothing that's installed is ever replaced by an offer.
    public static func offered(index: RuntimeIndex, installed: [String], appVersion: String?) -> RuntimeManifest? {
        guard let current = index.current, !index.pulled.contains(current.name),
              current.supports(appVersion: appVersion), !installed.contains(current.name) else { return nil }
        return current
    }

    /// The runtime a first install gets: the newest current runtime in the list this app can use (else the newest
    /// available one), else the runtime the app was built with unless it was pulled. Nil: this app is too old for
    /// every runtime in the list.
    public static func firstInstall(index: RuntimeIndex, appVersion: String?,
                                    bundled: RuntimeManifest? = RuntimeManifest.bundled()) -> RuntimeManifest? {
        let usable = index.runtimes.filter { $0.status != .pulled && $0.supports(appVersion: appVersion) }
        if let pick = usable.last(where: { ($0.status ?? .current) == .current }) ?? usable.last { return pick }
        guard let bundled, !index.pulled.contains(bundled.name) else { return nil }
        return bundled
    }

    /// Downloads (or copies, for file:// URLs and plain paths), verifies and unpacks a runtime.
    /// `progress` gets values from 0 to 1 while downloading. Replacing a runtime under running
    /// Wine processes could crash them, so this refuses while any bottle is running, both before
    /// the download (quick answer) and right before the swap (a game may have started meanwhile). A runtime
    /// with a new name installs next to the others and touches nothing else.
    public static func install(_ manifest: RuntimeManifest, into runtimes: URL = Paths.runtimes,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> Runtime {
        let fm = FileManager.default
        let source: URL
        if manifest.url.contains("://") {
            guard let url = URL(string: manifest.url), url.isFileURL || url.host?.isEmpty == false else {
                throw StepoverError.message("the runtime's download address isn't valid: \(manifest.url)")
            }
            source = url
        } else {
            source = URL(fileURLWithPath: manifest.url)
        }
        try ensureNothingRunning(manifest, in: runtimes)
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
        if let free = try? runtimes.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < manifest.neededBytes {
            throw StepoverError.message("not enough disk space: the runtime needs about \(String(format: "%.1f", Double(manifest.neededBytes) / 1e9)) GB free")
        }
        let work = runtimes.appendingPathComponent(".download")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("\(manifest.name).tar.xz")
        try? fm.removeItem(at: archive)

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
        let staging = runtimes.appendingPathComponent(".unpack-\(manifest.name)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", staging.path]
        try tar.run(); tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw StepoverError.message("unpacking the runtime failed (tar exit \(tar.terminationStatus))") }

        let unpacked = staging.appendingPathComponent(manifest.name)
        let dest = runtimes.appendingPathComponent(manifest.name)
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/wine").path) else {
            throw StepoverError.message("the runtime archive has no \(manifest.name)/bin/wine")
        }
        try ensureNothingRunning(manifest, in: runtimes)
        if fm.fileExists(atPath: dest.path) {
            let old = runtimes.appendingPathComponent("\(manifest.name).old")
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

    static func ensureNothingRunning(_ manifest: RuntimeManifest, in runtimes: URL) throws {
        let installed = FileManager.default.isExecutableFile(atPath: runtimes.appendingPathComponent("\(manifest.name)/bin/wine").path)
        if installed, let busy = Bottle.all().first(where: \.isRunning) {
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
