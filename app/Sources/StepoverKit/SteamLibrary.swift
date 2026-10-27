import Foundation

/// A game installed through Steam inside a bottle, from Steam's own records (appmanifest_<id>.acf).
public struct SteamApp: Hashable, Sendable {
    public let id: Int
    public let name: String
    public let folder: URL
    /// The folder as the game sees it, e.g. C:\Program Files (x86)\Steam\steamapps\common\Game
    public let windowsFolder: String

    public init(id: Int, name: String, folder: URL, windowsFolder: String) {
        self.id = id; self.name = name; self.folder = folder; self.windowsFolder = windowsFolder
    }

    /// A program file's full Windows path, lowercased: its section name in stepover-compat.conf
    /// (the plug-in matches a program by full path or by file name).
    public func windowsKey(_ program: URL) -> String {
        let base = folder.standardizedFileURL.path
        let relative = program.standardizedFileURL.path.dropFirst(base.count).split(separator: "/").joined(separator: "\\")
        return (windowsFolder + "\\" + relative).asciiLowercased
    }

    /// Program files in the game's folder (a few levels deep), without installers, redistributables
    /// and crash reporters: the programs a fix's settings go to.
    public func programs() -> [URL] { Self.programs(in: folder, depth: 4) }

    /// Program files in the game's top folder only: where a fix's launch arguments go.
    public func topPrograms() -> [URL] { Self.programs(in: folder, depth: 0) }

    static let helperPrefixes = ["unitycrashhandler", "crashreport", "crashpad", "crashhandler", "unins",
                                 "vc_redist", "vcredist", "dxsetup", "dotnet", "ue4prereq", "ueprereq", "physx"]
    static let helperFolders: Set = ["_commonredist", "redist", "__installer", "directx", "installers", "support"]

    static func programs(in folder: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0 && !helperFolders.contains(name) { out += programs(in: item, depth: depth - 1) }
            } else if name.hasSuffix(".exe") && !helperPrefixes.contains(where: { name.hasPrefix($0) }) {
                out.append(item)
            }
        }
        return out
    }
}

public enum SteamLibrary {
    /// Fully installed Steam games in the bottle, from every Steam library folder Steam knows of.
    public static func apps(in bottle: Bottle) -> [SteamApp] {
        var apps: [SteamApp] = []
        var seen = Set<Int>()
        for library in libraries(in: bottle) {
            let steamapps = library.mac.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8) else { continue }
                let values = topLevelValues(text)
                guard let id = values["appid"].flatMap(Int.init), let dir = values["installdir"], !seen.contains(id),
                      let flags = values["stateflags"].flatMap(Int.init), flags & 4 != 0 else { continue }  // 4 = fully installed
                seen.insert(id)
                let folder = steamapps.appendingPathComponent("common").appendingPathComponent(dir)
                apps.append(SteamApp(id: id, name: values["name"] ?? dir, folder: folder,
                                     windowsFolder: library.windows + #"\steamapps\common\"# + dir))
            }
        }
        return apps
    }

    /// Steam's own folder in the bottle plus the extra libraries in its libraryfolders.vdf.
    /// Each library as a Mac folder and as the Windows path Steam itself uses for it (games run
    /// under that path, so fixes are keyed by it rather than by a symlink-resolved one).
    static func libraries(in bottle: Bottle) -> [(mac: URL, windows: String)] {
        let candidates = [("Program Files (x86)/Steam", #"C:\Program Files (x86)\Steam"#), ("Program Files/Steam", #"C:\Program Files\Steam"#)]
        var out: [(mac: URL, windows: String)] = []
        for (relative, windowsSteam) in candidates {
            let steam = bottle.cDrive.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: steam.appendingPathComponent("steamapps").path) else { continue }
            out.append((steam, windowsSteam))
            let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
            guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            for path in quotedPairs(text).filter({ $0.0.lowercased() == "path" }).map(\.1) {
                let windows = path.replacingOccurrences(of: "\\\\", with: "\\")
                if let url = WindowsPath.toMac(windows, bottle: bottle.url),
                   url.standardizedFileURL != steam.standardizedFileURL, !out.contains(where: { $0.mac == url }) {
                    out.append((url, windows))
                }
            }
        }
        return out
    }

    /// "key" "value" pairs at the outermost level of a text VDF/ACF file, keys lowercased.
    static func topLevelValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var depth = 0
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "{" { depth += 1; continue }
            if t == "}" { depth -= 1; continue }
            if depth == 1, let pair = quotedPairs(t).first { out[pair.0.lowercased()] = pair.1 }
        }
        return out
    }

    static func quotedPairs(_ text: String) -> [(String, String)] {
        let regex = try! NSRegularExpression(pattern: #""([^"]*)"\s+"((?:[^"\\]|\\.)*)""#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let k = Range(m.range(at: 1), in: text), let v = Range(m.range(at: 2), in: text) else { return nil }
            return (String(text[k]), String(text[v]))
        }
    }
}
