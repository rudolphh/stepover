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

    /// DLSS on MetalFX: games find nvngx.dll through NGXCore's FullPath. CrossOver's bottles carry it, Wine's
    /// setup doesn't. Nil when the bottle has it already.
    public static func ngxPathPatch(_ bottle: Bottle) -> RegistryPatch? {
        let key = #"Software\NVIDIA Corporation\Global\NGXCore"#, path = #"C:\windows\system32"#
        guard bottle.systemRegistry.string(key, "FullPath")?.lowercased() != path.lowercased() else { return nil }
        var patch = RegistryPatch()
        patch.set(#"HKEY_LOCAL_MACHINE\"# + key, "FullPath", .string(path))
        return patch
    }

    /// DXMT's d3d11/dxgi import winemetal.dll, which isn't one of Wine's own DLLs. Wine loads such a DLL only through
    /// a placeholder on the search path (dlls/ntdll/loader.c, find_builtin_without_file), and Wine's setup makes
    /// none, so DXMT failed in every bottle Stepover made. Puts the runtime's own copies in system32 and syswow64
    /// where none is (CrossOver's bottles have them); Wine then loads the DLL from the runtime as usual.
    public static func placeDXMTPlaceholders(_ bottle: Bottle, runtime: Runtime) {
        let fm = FileManager.default
        for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let source = runtime.lib.appendingPathComponent("dxmt/\(arch)/winemetal.dll")
            let dir = bottle.cDrive.appendingPathComponent("windows/\(folder)")
            let target = dir.appendingPathComponent("winemetal.dll")
            guard fm.fileExists(atPath: source.path), fm.fileExists(atPath: dir.path), !fm.fileExists(atPath: target.path) else { continue }
            try? fm.copyItem(at: source, to: target)
        }
    }
}
