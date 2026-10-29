import Foundation

/// What kind of Windows installer a file is, told by what it holds (spec D5).
public enum InstallerKind: String, Codable, Sendable {
    case inno, nsis, msi, other

    /// Words for Details and the outcome record; never the installer's source.
    public var label: String {
        switch self {
        case .inno: return "Inno Setup installer"
        case .nsis: return "NSIS installer"
        case .msi: return "Windows Installer package"
        case .other: return "installer"
        }
    }
}

public struct Installer: Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case base, addOn, update }
    public var url: URL
    public var kind: InstallerKind
    public var role: Role

    public init(url: URL, kind: InstallerKind, role: Role) { self.url = url; self.kind = kind; self.role = role }
}

/// What a dropped item is (spec D1, D1b).
public enum DropPlan: Equatable, Sendable {
    case install([Installer])      // base, then add-ons by name, then updates in version order
    case installedGame(URL)        // copied into the bottle
    case several([URL])            // a folder of installer folders, each its own game
    case diskImage(URL)            // an .iso: AddGame.run mounts it read-only and plans its folder
    case archive, stillDownloading, nothing
}

public enum GameFolder {
    /// File extensions of downloads that haven't finished.
    public static let partialExtensions: Set<String> = ["part", "crdownload", "download", "!qb", "!ut", "aria2", "opdownload"]
    static let archives: Set<String> = ["zip", "rar", "7z"]

    /// By what the file holds: Inno Setup's loader ("rDlPtS"; uninstallers carry Inno's data marker but not this), NSIS
    /// ("NullsoftInst"), Windows Installer (.msi); else `.other` for setup*/install* names; nil when it isn't an installer.
    public static func kind(of file: URL) -> InstallerKind? {
        let ext = file.pathExtension.lowercased(), name = file.lastPathComponent.lowercased()
        if ext == "msi" { return .msi }
        guard ext == "exe", !name.hasPrefix("unins") else { return nil }
        if let data = try? Data(contentsOf: file, options: .alwaysMapped) {
            let limit = 64 << 20, window = 8 << 20
            let parts = data.count <= limit ? [data[...]] : [data.prefix(window), data.suffix(window)]
            if parts.contains(where: { $0.range(of: Data("rDlPtS".utf8)) != nil }) { return .inno }
            if parts.contains(where: { $0.range(of: Data("NullsoftInst".utf8)) != nil }) { return .nsis }
        }
        return name.hasPrefix("setup") || name.hasPrefix("install") ? .other : nil
    }

    /// A folder, a setup .exe or .msi (the base; other installers beside it follow), or a disk image or archive.
    public static func plan(for item: URL) -> DropPlan {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder) else { return .nothing }
        guard isFolder.boolValue else {
            let ext = item.pathExtension.lowercased()
            if archives.contains(ext) { return .archive }
            if ext == "iso" { return .diskImage(item) }
            guard let kind = kind(of: item) else { return .nothing }
            let others = installers(in: item.deletingLastPathComponent()).filter { $0.url.lastPathComponent != item.lastPathComponent }
            return .install(ordered(others, base: Installer(url: item, kind: kind, role: .base)))
        }
        if files(in: item, levels: 3).contains(where: { partialExtensions.contains($0.pathExtension.lowercased()) }) {
            return .stillDownloading
        }
        let top = installers(in: item)
        if !top.isEmpty { return .install(ordered(top, base: nil)) }
        let withInstallers = children(of: item).filter { isDirectory($0) && !installers(in: $0).isEmpty }
        if withInstallers.count >= 2 { return .several(withInstallers) }
        if let only = withInstallers.first { return plan(for: only) }
        let game = files(in: item, levels: 4).contains {
            $0.pathExtension.lowercased() == "exe" && !$0.lastPathComponent.lowercased().hasPrefix("unins")
                && PEFile(url: $0)?.isWindowed == true
        }
        return game ? .installedGame(item) : .nothing
    }

    static func installers(in folder: URL) -> [Installer] {
        children(of: folder).compactMap { url in kind(of: url).map { Installer(url: url, kind: $0, role: .addOn) } }
    }

    /// Updates ("patch…") last in natural order; the base is the dropped file, else the one with the shortest
    /// cleaned name (GOG: "tiny gog" before "tiny gog - extra"); the rest are add-ons by name.
    static func ordered(_ found: [Installer], base: Installer?) -> [Installer] {
        func natural(_ a: Installer, _ b: Installer) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        var updates = found.filter { $0.url.lastPathComponent.lowercased().hasPrefix("patch") }.sorted(by: natural)
        for i in updates.indices { updates[i].role = .update }
        var rest = found.filter { !$0.url.lastPathComponent.lowercased().hasPrefix("patch") }.sorted(by: natural)
        var first = base
        if first == nil, let shortest = rest.min(by: {
            FolderName.clean($0.url.lastPathComponent).count < FolderName.clean($1.url.lastPathComponent).count
        }) {
            first = shortest
            rest.removeAll { $0.url == shortest.url }
        }
        guard var head = first ?? updates.first else { return [] }
        if first == nil { updates.removeFirst() }
        head.role = .base
        return [head] + rest.map { var addOn = $0; addOn.role = .addOn; return addOn } + updates
    }

    static func children(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appendingPathComponent($0) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Files at most `levels` deep (1: the folder's own files).
    static func files(in folder: URL, levels: Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            if walker.level >= levels { walker.skipDescendants() }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(url) }
        }
        return out
    }
}
