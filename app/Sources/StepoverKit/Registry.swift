import Foundation

/// Reads values from a bottle's Wine registry files (user.reg / system.reg) without starting Wine.
/// Writes go through regedit in the bottle (see Bottle.importRegistry), as CrossOver does.
public struct RegistryFile {
    /// lowercased key -> lowercased value name -> raw data as written in the file
    public private(set) var keys: [String: [String: String]] = [:]

    public init(url: URL) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        else { return }
        var current: String?
        var pending = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = pending.isEmpty ? String(raw) : pending + raw.trimmingCharacters(in: .whitespaces)
            pending = ""
            if line.hasSuffix("\\"), !line.hasPrefix("[") {  // hex data continues on the next line
                line.removeLast()
                pending = line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { continue }
                let key = String(line[line.index(after: line.startIndex)..<close]).replacingOccurrences(of: "\\\\", with: "\\")
                current = key.lowercased()
                if keys[current!] == nil { keys[current!] = [:] }
            } else if let key = current, let eq = Self.splitValue(line) {
                keys[key, default: [:]][eq.0.lowercased()] = eq.1
            }
        }
    }

    /// "name"=data or @=data
    static func splitValue(_ line: String) -> (String, String)? {
        if line.hasPrefix("@=") { return ("@", String(line.dropFirst(2))) }
        guard line.hasPrefix("\"") else { return nil }
        var escaped = false
        var name = ""
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let c = line[index]
            if escaped { name.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { break }
            else { name.append(c) }
            index = line.index(after: index)
        }
        let rest = line[line.index(after: index)...]
        guard rest.hasPrefix("=") else { return nil }
        return (name, String(rest.dropFirst()))
    }

    public func raw(_ key: String, _ name: String) -> String? { keys[key.lowercased()]?[name.lowercased()] }

    public func string(_ key: String, _ name: String) -> String? {
        guard let raw = raw(key, name), raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return nil }
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
    }

    public func dword(_ key: String, _ name: String) -> UInt32? {
        guard let raw = raw(key, name), raw.hasPrefix("dword:") else { return nil }
        return UInt32(raw.dropFirst(6), radix: 16)
    }
}

/// REGEDIT4 text for regedit's /S import.
public struct RegistryPatch {
    public enum Value { case string(String), dword(UInt32), delete }
    var entries: [(key: String, name: String, value: Value)] = []
    public init() {}

    public mutating func set(_ key: String, _ name: String, _ value: Value) { entries.append((key, name, value)) }

    public var text: String {
        var out = "REGEDIT4\r\n"
        var lastKey: String?
        for e in entries {
            if e.key != lastKey { out += "\r\n[\(e.key)]\r\n"; lastKey = e.key }
            let name = "\"" + e.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            switch e.value {
            case .string(let s):
                out += "\(name)=\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\r\n"
            case .dword(let d): out += "\(name)=dword:\(String(format: "%08x", d))\r\n"
            case .delete: out += "\(name)=-\r\n"
            }
        }
        return out + "\r\n"
    }
}
