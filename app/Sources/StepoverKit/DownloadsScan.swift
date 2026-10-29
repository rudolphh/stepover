import Foundation

/// Couch mode's Menu > Add a Game: the games waiting in Downloads (spec D12).
public enum DownloadsScan {
    /// Top-level folders that hold an installer or a game, and .iso files, newest first. Anything still downloading
    /// (partial-download files, or a file changed in the last minute) is left out.
    public static func candidates(in folder: URL, now: Date = Date()) -> [URL] {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let found = GameFolder.children(of: folder).filter { item in
            switch GameFolder.plan(for: item) {
            case .install, .installedGame, .diskImage: break
            default: return false
            }
            let recent = ([item] + GameFolder.files(in: item, levels: 2)).contains { now.timeIntervalSince(modified($0)) < 60 }
            return !recent
        }
        return found.sorted { modified($0) > modified($1) }
    }
}
