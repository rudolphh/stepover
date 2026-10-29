import Foundation

/// A game's name from the folder (or installer file) it came in: "Red.Dead.Redemption.2.Build.1436.28-TAG" is
/// "Red Dead Redemption 2". Generic rules only; no installer group is named anywhere.
public enum FolderName {
    static let extensions: Set<String> = ["exe", "msi", "iso", "zip", "rar", "7z"]
    static let words: Set<String> = ["setup", "installer", "install", "repack", "x64", "x86", "64-bit", "64bit", "32-bit", "32bit"]

    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let dot = text.lastIndex(of: "."), extensions.contains(text[text.index(after: dot)...].lowercased()) {
            text = String(text[..<dot])
        }
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#, with: " ", options: .regularExpression)
        // Scene-style names use dots or underscores for spaces and may end in "-TAG".
        let separated = !text.trimmingCharacters(in: .whitespaces).contains(" ") && (text.contains(".") || text.contains("_"))
        if separated, let range = text.range(of: #"-([A-Za-z0-9]+)\s*$"#, options: .regularExpression),
           isTag(String(text[range].dropFirst()).trimmingCharacters(in: .whitespaces)) {
            text.removeSubrange(range)
        }

        var tokens: [String] = []
        for piece in text.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init) {
            if !separated || isVersion(piece) { tokens.append(piece) } else { tokens += piece.split(separator: ".").map(String.init) }
        }
        var kept: [String] = []
        var afterVersion = false
        for token in tokens {
            let lower = token.lowercased()
            if lower == "build" || lower.range(of: #"^v\d+(\.\d+)*$"#, options: .regularExpression) != nil {
                afterVersion = true
                continue
            }
            if afterVersion, token.allSatisfy(\.isNumber) || isVersion(token) { continue }
            afterVersion = false
            if isVersion(token) || words.contains(lower) { continue }
            kept.append(token)
        }
        let name = kept.joined(separator: " ")
        return name.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : name
    }

    /// "1.0.2", "v4.04": dotted numbers, or v and a number.
    static func isVersion(_ token: String) -> Bool {
        token.range(of: #"^[vV]?\d+(\.\d+)+$|^[vV]\d+$"#, options: .regularExpression) != nil
    }

    /// A release tag: all capitals or digits, a capital after the first letter, or a digit ("Man" in "Spider-Man" is not one).
    static func isTag(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return true }
        return word.dropFirst().contains(where: \.isUppercase) || word.contains(where: \.isNumber)
    }
}
