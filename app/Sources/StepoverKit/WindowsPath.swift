import Foundation

/// Windows <-> Mac path conversion through a bottle's dosdevices folder.
public enum WindowsPath {
    public static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    public static func directory(_ path: String) -> String {
        guard let cut = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return path }
        return String(path[..<cut])
    }

    /// C:\Games\x.exe -> <bottle>/dosdevices/c:/Games/x.exe, resolved through the drive's symlink.
    public static func toMac(_ path: String, bottle: URL) -> URL? {
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":", chars[0].isLetter else { return nil }
        let drive = bottle.appendingPathComponent("dosdevices/\(chars[0].lowercased()):").resolvingSymlinksInPath()
        let rest = String(chars.dropFirst(2)).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        var url = drive
        for part in rest { url.appendPathComponent(part) }
        return url
    }

    /// A Mac file inside the bottle (or anywhere, through Z:) -> its Windows path.
    public static func toWindows(_ url: URL, bottle: URL) -> String {
        let target = url.resolvingSymlinksInPath().path
        let devices = bottle.appendingPathComponent("dosdevices")
        let drives = ((try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? [])
            .filter { $0.count == 2 && $0.hasSuffix(":") }
            .compactMap { name -> (String, String)? in
                let root = devices.appendingPathComponent(name).resolvingSymlinksInPath().path
                return (name.uppercased(), root)
            }
            .sorted { $0.1.count > $1.1.count }  // most specific mount first; Z: (/) last
        for (drive, root) in drives {
            let prefix = root == "/" ? "/" : root + "/"
            if target == root { return drive + "\\" }
            if target.hasPrefix(prefix) {
                return drive + "\\" + target.dropFirst(prefix.count).replacingOccurrences(of: "/", with: "\\")
            }
        }
        return "Z:" + target.replacingOccurrences(of: "/", with: "\\")
    }
}
