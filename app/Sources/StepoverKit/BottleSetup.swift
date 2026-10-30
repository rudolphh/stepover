import Foundation

/// How bottles made for added games differ from Wine's defaults (spec D4).
public enum BottleSetup {
    public static let personal = ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"]

    /// Windows makes C:\users\Public\Downloads at setup; Wine doesn't, and Rockstar's launcher service fails to find
    /// FOLDERID_PublicDownloads without it.
    public static func makePublicDownloads(_ bottle: Bottle) throws {
        try FileManager.default.createDirectory(at: bottle.cDrive.appendingPathComponent("users/Public/Downloads"),
                                                withIntermediateDirectories: true)
    }

    /// Replaces Wine's links from C:\users\crossover to the Mac's own folders with real folders, each holding
    /// `.stepover-keep` so Wine can't swap an empty one back for a link. No macOS access dialog can then stall an
    /// install, and a game's saves stay with the game. What the links pointed at is not touched.
    public static func keepPersonalFoldersInside(_ bottle: Bottle) throws {
        let fm = FileManager.default
        let profile = bottle.cDrive.appendingPathComponent("users/crossover")
        for name in personal {
            let folder = profile.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil { try fm.removeItem(at: folder) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let keep = folder.appendingPathComponent(".stepover-keep")
            if !fm.fileExists(atPath: keep.path) { try Data().write(to: keep) }
        }
    }
}
