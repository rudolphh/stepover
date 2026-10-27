import Foundation

/// Reads a Windows shortcut (.lnk, MS-SHLLINK) for its target, arguments and working directory.
public struct ShellLink {
    public var target: String?
    public var arguments: String?
    public var workdir: String?

    public init?(url: URL) {
        guard let d = try? Data(contentsOf: url), d.count >= 0x4C, d[0] == 0x4C else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? (0..<4).reduce(0) { $0 | Int(d[o + $1]) << (8 * $1) } : 0 }
        func ansi(_ o: Int) -> String? {
            guard o < d.count else { return nil }
            var e = o
            while e < d.count, d[e] != 0 { e += 1 }
            return String(decoding: d[o..<e], as: UTF8.self)
        }
        func utf16(_ range: Range<Int>) -> String {  // little-endian on disk
            var units: [UInt16] = []
            var i = range.lowerBound
            while i + 1 < range.upperBound, i + 1 < d.count { units.append(UInt16(d[i]) | UInt16(d[i + 1]) << 8); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        let flags = u32(0x14)
        let hasIDList = flags & 0x1 != 0, hasLinkInfo = flags & 0x2 != 0
        let hasName = flags & 0x4 != 0, hasRelPath = flags & 0x8 != 0, hasWorkDir = flags & 0x10 != 0
        let hasArgs = flags & 0x20 != 0, unicode = flags & 0x80 != 0

        var pos = 0x4C
        if hasIDList { pos += 2 + u16(pos) }
        if hasLinkInfo {
            let size = u32(pos)
            let infoFlags = u32(pos + 8)
            if infoFlags & 0x1 != 0 {  // VolumeIDAndLocalBasePath
                let headerSize = u32(pos + 4)
                if headerSize >= 0x24, u32(pos + 0x1C) != 0 {  // LocalBasePathOffsetUnicode
                    let o = pos + u32(pos + 0x1C)
                    var e = o
                    while e + 1 < d.count, d[e] != 0 || d[e + 1] != 0 { e += 2 }
                    target = utf16(o..<e)
                } else {
                    target = ansi(pos + u32(pos + 0x10))
                }
                let suffix = ansi(pos + u32(pos + 0x18)) ?? ""
                if let t = target, !suffix.isEmpty { target = t + suffix }
            }
            pos += size
        }
        func string() -> String {
            let count = u16(pos)
            pos += 2
            let bytes = unicode ? count * 2 : count
            guard pos + bytes <= d.count else { pos = d.count; return "" }
            let s = unicode ? utf16(pos..<pos + bytes) : String(decoding: d[pos..<pos + bytes], as: UTF8.self)
            pos += bytes
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))  // some writers count the terminator
        }
        if hasName { _ = string() }
        let relative = hasRelPath ? string() : nil
        if hasWorkDir { workdir = string() }
        if hasArgs { arguments = string() }
        if target == nil, let relative, relative.contains(":") { target = relative }
        if target == nil { return nil }
    }
}
