import CryptoKit
import Foundation

/// Checks an installer folder against the checksum lists that came with it (.md5, .sfv), after an install failed:
/// damaged downloads are the commonest real failure (spec D9).
public enum ChecksumCheck {
    /// Files listed in .md5 and .sfv files (in the folder and one folder down; paths may start with ..\) that are
    /// missing or differ; nil when there are no such lists.
    public static func damaged(in folder: URL) -> Int? {
        let lists = GameFolder.files(in: folder, levels: 2).filter { ["md5", "sfv"].contains($0.pathExtension.lowercased()) }
        var checked = 0, bad = 0
        for list in lists {
            guard let text = try? String(contentsOf: list, encoding: .utf8) ?? String(contentsOf: list, encoding: .isoLatin1) else { continue }
            let md5 = list.pathExtension.lowercased() == "md5"
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix(";"), let entry = md5 ? md5Entry(line) : sfvEntry(line) else { continue }
                let file = list.deletingLastPathComponent().appendingPathComponent(entry.path.replacingOccurrences(of: "\\", with: "/"))
                    .standardizedFileURL
                checked += 1
                let actual = md5 ? md5Hex(file) : crc32Hex(file)
                if actual?.lowercased() != entry.sum.lowercased() { bad += 1 }
            }
        }
        return checked == 0 ? nil : bad
    }

    /// "<32 hex> *path" or "<32 hex>  path".
    static func md5Entry(_ line: String) -> (sum: String, path: String)? {
        guard let match = line.range(of: #"^[0-9A-Fa-f]{32}\s+\*?"#, options: .regularExpression) else { return nil }
        let sum = String(line.prefix(32)), path = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : (sum, path)
    }

    /// "path <8 hex>".
    static func sfvEntry(_ line: String) -> (sum: String, path: String)? {
        guard let match = line.range(of: #"\s+[0-9A-Fa-f]{8}$"#, options: .regularExpression) else { return nil }
        let path = String(line[..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : (String(line.suffix(8)), path)
    }

    static func chunks(_ file: URL, _ body: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty { body(data) }
        return true
    }

    static func md5Hex(_ file: URL) -> String? {
        var hash = Insecure.MD5()
        guard chunks(file, { hash.update(data: $0) }) else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32Hex(_ file: URL) -> String? {
        var crc: UInt32 = 0xFFFF_FFFF
        guard chunks(file, { data in for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) } }) else { return nil }
        return String(format: "%08x", crc ^ 0xFFFF_FFFF)
    }
}
