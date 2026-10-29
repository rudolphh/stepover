import Foundation

/// Couch mode's rules: moving along the row of games, the controller shortcut that brings up the in-game
/// panel, and what A does. Spec: docs/superpowers/specs/2026-10-28-couch-mode-design.md.
public enum CouchButton: Hashable, Sendable { case up, down, left, right, a, b, x, y, menu, select, home }

/// Focus on the row of games: clamps at both ends, never wraps.
public struct CouchRow: Sendable {
    public private(set) var index: Int
    public let count: Int

    public init(count: Int, index: Int = 0) {
        self.count = count
        self.index = count == 0 ? 0 : min(max(index, 0), count - 1)
    }

    public mutating func move(_ step: Int) {
        guard count > 0 else { return }
        index = min(max(index + step, 0), count - 1)
    }

    /// Moves a held direction has made after `seconds`: one at once, then one every `repeatEvery` seconds once
    /// it has been held `repeatAfter` seconds.
    public static func repeats(heldFor seconds: Double, repeatAfter: Double = 0.4, repeatEvery: Double = 0.12) -> Int {
        guard seconds > repeatAfter else { return 1 }
        return 1 + Int(((seconds - repeatAfter) / repeatEvery) + 1e-9)
    }
}

/// Holding Home (homeHold seconds) or Select and Start together (chordHold seconds). Fires once per hold.
public struct ShortcutDetector: Sendable {
    public static let homeHold = 0.5, chordHold = 1.0
    private var homeSince: Double?, chordSince: Double?
    private var fired = false

    public init() {}

    public mutating func update(_ pressed: Set<CouchButton>, at time: Double) -> Bool {
        let home = pressed.contains(.home), chord = pressed.contains(.select) && pressed.contains(.menu)
        homeSince = home ? (homeSince ?? time) : nil
        chordSince = chord ? (chordSince ?? time) : nil
        if !home && !chord { fired = false }   // re-arms once let go
        guard !fired else { return false }
        if let start = homeSince, time - start >= Self.homeHold { fired = true; return true }
        if let start = chordSince, time - start >= Self.chordHold { fired = true; return true }
        return false
    }
}

public enum CouchAction: Equatable, Sendable { case play, resume, quitAndPlay(running: String), why, hide, back, menu, none }

public enum Couch {
    /// What A does on `selected` while `running` (a LibraryGame id) is running.
    public static func primary(selected: String, running: String?) -> CouchAction {
        guard let running else { return .play }
        return running == selected ? .resume : .quitAndPlay(running: running)
    }
}

/// How to quit just one game: a Steam game's own processes (Steam keeps running and syncs its cloud saves),
/// else the game's bottle.
public enum QuitPlan: Equatable, Sendable { case processes([Int32]), bottle(Bottle) }

extension Couch {
    /// The library game that's running: a Steam game when a non-system process in its bottle runs from its
    /// folder; a program when its exe runs in its bottle. The Steam client alone isn't a game running.
    public static func running(_ games: [LibraryGame], processes: [RunningPrograms.Process]) -> LibraryGame? {
        games.first { !self.processes(of: $0, in: processes).isEmpty }
    }

    public static func quitPlan(_ game: LibraryGame, processes: [RunningPrograms.Process]) -> QuitPlan {
        if case .steamGame = game.kind { return .processes(self.processes(of: game, in: processes).map(\.pid)) }
        return .bottle(game.bottle)
    }

    /// The game's own processes: what Resume brings forward and what Quit Game ends for a Steam game.
    public static func processes(of game: LibraryGame, in processes: [RunningPrograms.Process]) -> [RunningPrograms.Process] {
        let inBottle = RunningPrograms.inBottle(processes, bottlePath: game.bottle.url.path).filter { !$0.isSystem }
        switch game.kind {
        case .steamGame(let app):
            let folder = app.windowsFolder.lowercased() + "\\"
            return inBottle.filter { $0.windowsPath.lowercased().hasPrefix(folder) }
        case .program(let program):
            let exe = WindowsPath.fileName(program.exe).lowercased()
            return inBottle.filter { $0.exeName == exe }
        case .steamClient:
            return []
        }
    }
}
