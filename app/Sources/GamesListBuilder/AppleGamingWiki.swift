import Foundation

/// One AppleGamingWiki page's Mac results: its Compatibility/macOS block and Infobox Steam app id.
public struct AGWPage: Equatable, Sendable {
    public var title: String
    public var steam: Int?
    public var tests: MacTests

    public init(title: String, steam: Int?, tests: MacTests) { self.title = title; self.steam = steam; self.tests = tests }
}

/// Reads AppleGamingWiki's hand-typed wikitext (CC BY-NC-SA 3.0). Fields are free text, so everything is
/// trimmed and lowercased, and anything that isn't one of the four ratings counts as untested.
public enum AppleGamingWiki {
    static let methods: [(field: String, path: WritableKeyPath<MacTests, MacTest?>)] =
        [("native", \.native), ("rosetta 2", \.rosetta), ("crossover", \.crossover), ("wine", \.wine)]

    /// Nil when the page has no Compatibility/macOS block.
    public static func parse(title: String, wikitext: String) -> AGWPage? {
        guard let start = wikitext.range(of: "{{Compatibility/macOS") else { return nil }
        var fields: [String: String] = [:], last: String?
        var depth = 1   // template nesting: a {{Refdevice ...}} can span lines whose own "|key=" aren't fields
        for line in wikitext[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if depth == 1 && text.hasPrefix("}}") { break }
            if depth == 1, text.hasPrefix("|"), let equals = text.firstIndex(of: "=") {
                let key = text[text.index(after: text.startIndex)..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                last = key
            } else if let last, !text.isEmpty {
                fields[last, default: ""] += " " + text   // a value that runs onto the next line
            }
            depth += text.components(separatedBy: "{{").count - text.components(separatedBy: "}}").count
            if depth < 1 { break }
        }
        var tests = MacTests()
        for (field, path) in methods {
            guard let word = fields[field]?.split(whereSeparator: { !$0.isLetter }).first?.lowercased(),
                  let rating = MacRating(rawValue: word) else { continue }
            var test = MacTest(rating: rating)
            if let ref = fields[field + " notes"].flatMap(refdevice) {
                test.device = ref["device"].flatMap(nonEmpty)
                test.method = ref["method"].flatMap(nonEmpty).map(method)
                test.date = ref["date"].flatMap(date)
            }
            tests[keyPath: path] = test
        }
        return AGWPage(title: title, steam: steamAppID(wikitext), tests: tests)
    }

    /// The pages in an API answer to prop=revisions; throws on an error answer, so the run keeps the previous
    /// list's results instead of losing these pages for a day.
    public static func pages(revisionsAnswer data: Data) throws -> [AGWPage] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["error"] == nil,
              let query = body["query"] as? [String: Any] else {
            throw Fetch.Failure(description: "AppleGamingWiki answered with an error")
        }
        return (query["pages"] as? [[String: Any]] ?? []).compactMap { page in
            guard let title = page["title"] as? String,
                  let revision = (page["revisions"] as? [[String: Any]])?.first,
                  let text = ((revision["slots"] as? [String: Any])?["main"] as? [String: Any])?["content"] as? String
            else { return nil }
            return parse(title: title, wikitext: text)
        }
    }

    /// The first number on the Infobox's "|steam appid =" line.
    static func steamAppID(_ wikitext: String) -> Int? {
        for line in wikitext.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("|"), let equals = text.firstIndex(of: "="),
                  text[text.index(after: text.startIndex)..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "steam appid"
            else { continue }
            return text[text.index(after: equals)...].split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        }
        return nil
    }

    /// The fields of the first {{Refdevice|key=value|...}} in a notes value.
    static func refdevice(_ notes: String) -> [String: String]? {
        guard let start = notes.range(of: "{{Refdevice|") else { return nil }
        let rest = notes[start.upperBound...]
        let body = rest.range(of: "}}").map { rest[..<$0.lowerBound] } ?? rest
        var out: [String: String] = [:]
        for part in body.split(separator: "|") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            out[part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()] =
                part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// "Crossover 25.0 (25.0.0.38553)" -> "Crossover 25.0": the build number in parentheses dropped.
    public static func method(_ text: String) -> String {
        text.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "2025-05-05", "2025-05" or nil, from "2025-05-12", "May 5th, 2025", "12 March 2024", "June 2023"...
    public static func date(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        if parts.count >= 2, parts.count <= 3, parts.allSatisfy({ Int($0) != nil }), parts[0].count == 4 {
            // day and month typed the other way round ("2021-24-10") aren't a date
            guard (1...12).contains(Int(parts[1])!), parts.count == 2 || (1...31).contains(Int(parts[2])!) else { return nil }
            return parts.enumerated().map { $0.offset == 0 ? String($0.element) : String(format: "%02d", Int($0.element)!) }
                .joined(separator: "-")
        }
        var year: Int?, month: Int?, day: Int?
        for token in text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "/" }) {
            let digits = token.prefix { $0.isNumber }
            if digits.count == 4, let value = Int(digits) { year = value }
            else if !digits.isEmpty, digits.count <= 2, let value = Int(digits), (1...31).contains(value) { day = value }
            else if token.count >= 3, let index = months.firstIndex(of: String(token.prefix(3))) { month = index + 1 }
        }
        guard let year, let month else { return nil }
        return day.map { String(format: "%04d-%02d-%02d", year, month, $0) } ?? String(format: "%04d-%02d", year, month)
    }
}
