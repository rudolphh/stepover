import Foundation

/// How a game went on this Mac (recorded by the session watcher, Library plan C).
public enum PlayResult: Equatable, Sendable { case runs(minutes: Int), problems }

/// One fact behind a verdict, and where it comes from.
public struct Reason: Equatable, Sendable {
    public var text: String
    public var source: String?
    public init(text: String, source: String?) { self.text = text; self.source = source }
}

public struct PlayVerdict: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case yourRuns, yourProblems, macVersion, doesntRun, antiCheatBlocked, singlePlayerOnly,
             playsGreat, playable, startsWithProblems, shouldPlay, probablyWontRun, notTested
    }
    public var kind: Kind
    public var headline: String
    public var extra: [String]      // added lines: the single-player line, then the fix line
    public var reasons: [Reason]    // every fact behind it, whatever the headline
}

public enum ControllerVerdict: String, Sendable {
    case yours = "Played with a controller on this Mac"
    case full = "Full controller support"
    case worksMenusMouse = "Controller works; some menus may need a mouse"
    case partial = "Partial controller support"
    case keyboardMouse = "Keyboard and mouse"
}

/// The Library's two plain answers for a game: will it play on this Mac, and does it work with a controller.
/// Rules and copy: docs/superpowers/specs/2026-10-28-library-design.md, Verdicts.
public enum Verdicts {
    /// Mac tests dated before this predate Apple's D3DMetal.
    public static let d3dmetalSince = "2023-06"

    static let notTested = "Not tested yet. Try it; Stepover will remember how it went."
    static let singlePlayerLine = "Single-player only: online play needs anti-cheat that doesn't work on Mac"
    public static let fixLine = "Stepover applies a fix for this game automatically"

    public static func play(_ entry: GameEntry?, yourResult: PlayResult? = nil) -> PlayVerdict {
        var extra: [String] = []
        func verdict(_ kind: PlayVerdict.Kind, _ headline: String) -> PlayVerdict {
            PlayVerdict(kind: kind, headline: headline, extra: extra + (entry?.fix == true ? [fixLine] : []),
                        reasons: entry.map(reasons) ?? [])
        }
        switch yourResult {
        case .runs(let minutes)?:
            let played = minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
            return verdict(.yourRuns, "Runs on this Mac (you played \(played))")
        case .problems?:
            return verdict(.yourProblems, "Had problems on this Mac")
        case nil:
            break
        }
        guard let entry else { return verdict(.notTested, notTested) }

        let native = entry.mac?.native, crossover = entry.mac?.crossover, wine = entry.mac?.wine
        if entry.store?.macVersion == true, native?.rating != .unplayable {
            return verdict(.macVersion, native == nil ? "There's a Mac version (not checked on current macOS)" : "There's a Mac version")
        }

        let doesntRun = (crossover?.rating == .unplayable && (wine == nil || wine?.rating == .unplayable))
            || (wine?.rating == .unplayable && crossover == nil)
        let deckGood = entry.deck?.category == .verified || entry.deck?.category == .playable
        let onlyOldTests = [crossover, wine].compactMap { $0 }.filter { $0.rating == .unplayable }.allSatisfy(isOld)
        if doesntRun && !(onlyOldTests && deckGood) { return verdict(.doesntRun, "Doesn't run on Mac yet") }

        let best = [crossover, wine].compactMap { $0?.rating }.max()
        let tested: (PlayVerdict.Kind, String)? = switch best {
        case .perfect?: (.playsGreat, "Plays great (tested on Mac)")
        case .playable?: (.playable, "Playable (tested on Mac)")
        case .runs?: (.startsWithProblems, "Starts, with problems (tested on Mac)")
        default: nil
        }

        if entry.antiCheat != nil {
            if let tested, let best, best >= .playable {
                extra.append(singlePlayerLine)
                return verdict(tested.0, tested.1)
            }
            if entry.store?.singlePlayer == true { return verdict(.singlePlayerOnly, singlePlayerLine) }
            return verdict(.antiCheatBlocked, "Won't run: needs anti-cheat that doesn't work on Mac")
        }
        if let tested { return verdict(tested.0, tested.1) }

        switch entry.deck?.category {
        case .verified?, .playable?: return verdict(.shouldPlay, "Should play (works on Steam Deck, not tested on Mac yet)")
        case .unsupported?: return verdict(.probablyWontRun, "Probably won't run")
        default: return verdict(.notTested, notTested)
        }
    }

    /// A headline as its answer and its qualifier, so couch mode can set the answer bold and keep the Library's
    /// words: "Plays great (tested on Mac)", "Won't run: needs ...", "Not tested yet. Try it; ...".
    public static func parts(_ headline: String) -> (String, String?) {
        if headline.hasSuffix(")"), let open = headline.range(of: " (") {
            return (String(headline[..<open.lowerBound]), String(headline[open.upperBound...].dropLast()))
        }
        for separator in [": ", ". "] {
            if let at = headline.range(of: separator) { return (String(headline[..<at.lowerBound]), String(headline[at.upperBound...])) }
        }
        return (headline, nil)
    }

    public static func controller(_ entry: GameEntry?, playedWithController: Bool = false) -> ControllerVerdict? {
        if playedWithController { return .yours }
        guard let store = entry?.store else { return nil }
        switch store.controller {
        case .full?: return .full
        case .partial?: return entry?.deck?.controllerWorks == true ? .worksMenusMouse : .partial
        case nil: return .keyboardMouse
        }
    }

    static func isOld(_ test: MacTest) -> Bool {
        guard let date = test.date else { return false }
        return date.prefix(7) < d3dmetalSince
    }

    static func reasons(_ entry: GameEntry) -> [Reason] {
        var out: [Reason] = []
        for (test, label) in [(entry.mac?.crossover, "CrossOver"), (entry.mac?.wine, "Wine")] {
            guard let test else { continue }
            if test.rating == .unplayable, isOld(test), let year = test.date?.prefix(4) {
                out.append(Reason(text: "An older Mac test (\(year)) didn't run.", source: agwSource(test)))
            } else {
                let device = test.device.map { " on \($0)" } ?? ""
                out.append(Reason(text: "Tested with \(method(test.method, label: label))\(device): \(word(test.rating)).", source: agwSource(test)))
            }
        }
        if entry.store?.macVersion == true { out.append(Reason(text: "Steam sells a native Mac version.", source: "Steam")) }
        if entry.mac?.native?.rating == .unplayable {
            out.append(Reason(text: "The old Mac version doesn't run on current macOS.", source: "AppleGamingWiki"))
        }
        if let antiCheat = entry.antiCheat, !antiCheat.names.isEmpty {
            let verb = antiCheat.names.count == 1 ? "doesn't" : "don't"
            out.append(Reason(text: "Uses \(RuntimeCatalog.joined(antiCheat.names)), which \(verb) work on Mac.", source: "AreWeAntiCheatYet"))
        }
        switch entry.deck?.category {
        case .verified?: out.append(Reason(text: "Steam Deck: Verified.", source: "Valve"))
        case .playable?: out.append(Reason(text: "Steam Deck: Playable.", source: "Valve"))
        case .unsupported?: out.append(Reason(text: "Steam Deck: Unsupported.", source: "Valve"))
        default: break
        }
        return out
    }

    /// The tester's method when it reads like a product and an optional version ("Crossover 25.0", "Whisky 2.3"),
    /// else the plain label: free text like "Installed through Steam." or "Crossover 23.6 D3DMetal enabled"
    /// doesn't belong on the verdict card.
    static func method(_ text: String?, label: String) -> String {
        guard let text, text.range(of: #"^[A-Za-z]+( [0-9][0-9.]*)?$"#, options: .regularExpression) != nil else { return label }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return ([parts[0].lowercased() == "crossover" ? "CrossOver" : parts[0]] + parts.dropFirst()).joined(separator: " ")
    }

    static func word(_ rating: MacRating) -> String {
        switch rating {
        case .perfect: return "perfect"
        case .playable: return "playable"
        case .runs: return "starts, with problems"
        case .unplayable: return "doesn't run"
        }
    }

    /// "AppleGamingWiki, May 2025" when the test's date has a month, else "AppleGamingWiki".
    static func agwSource(_ test: MacTest) -> String {
        let parts = (test.date ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]), let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1]))
        else { return "AppleGamingWiki" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMM yyyy"
        return "AppleGamingWiki, " + format.string(from: date)
    }
}
