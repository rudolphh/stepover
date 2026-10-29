import Darwin
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

    /// Focus on the game `focus` wherever the row put it (playing a game moves it to the front); when it's gone
    /// (hidden), on the game that took its place, `fallback`.
    public init(ids: [String], focus: String?, fallback: Int) {
        self.init(count: ids.count, index: focus.flatMap { ids.firstIndex(of: $0) } ?? fallback)
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

/// Turns the controller's pressed buttons, read every few milliseconds, into presses: each newly pressed button
/// once, and a held direction again at CouchRow.repeats' pace. While Stepover isn't in front (a game has the
/// controller) nothing counts, and a button still held when Stepover comes back doesn't count until let go.
public struct PressTracker: Sendable {
    private var held: Set<CouchButton> = []
    private var since: [CouchButton: Double] = [:]
    private var sent: [CouchButton: Int] = [:]

    public init() {}

    public mutating func update(_ pressed: Set<CouchButton>, at time: Double, active: Bool) -> [CouchButton] {
        defer { held = pressed }
        guard active else { since = [:]; sent = [:]; return [] }
        var out: [CouchButton] = []
        for button in pressed.subtracting(held) { since[button] = time; sent[button] = 1; out.append(button) }
        for button in held.subtracting(pressed) { since[button] = nil; sent[button] = nil }
        for button in pressed.intersection([.up, .down, .left, .right]) {
            guard let start = since[button] else { continue }
            let due = CouchRow.repeats(heldFor: time - start)
            while (sent[button] ?? 1) < due { sent[button, default: 1] += 1; out.append(button) }
        }
        return out
    }
}

/// The in-game panel's pause: the game's processes are stopped while the panel is up, so the panel's buttons never
/// act in it. Resume continues them once every button is let go (an A still held when the game continues would reach
/// it); a quit, the game ending or another game taking over continues them at once. Pure: the app sends the signals.
public struct InGamePause: Sendable {
    public private(set) var paused: [Int32] = []
    private var game: String?
    private var resuming = false

    public init() {}

    /// The panel shows over `game`: stop these (and forget any Resume still waiting for buttons to be let go).
    public mutating func pause(_ game: String, pids: [Int32]) -> [Int32] {
        self.game = game; paused = pids; resuming = false
        return pids
    }

    public mutating func resume() { resuming = !paused.isEmpty }

    /// Each poll of the controller: what to continue now.
    public mutating func update(_ pressed: Set<CouchButton>) -> [Int32] {
        guard resuming, pressed.isEmpty else { return [] }
        return release()
    }

    /// The running game, as Store sees it every 2 s: a different one, or none, continues what was paused.
    public mutating func watching(_ game: String?) -> [Int32] { game == self.game ? [] : release() }

    /// Quit Game: continue them first, since a stopped process can't take a signal to end.
    public mutating func quit() -> [Int32] { release() }

    private mutating func release() -> [Int32] {
        defer { paused = []; game = nil; resuming = false }
        return paused
    }
}

/// Ending a Steam game's own processes (Steam keeps running): continued (a paused one can't take SIGTERM), asked to
/// end, and killed if still there after `grace` seconds; done as soon as they're all gone.
public enum ProcessEnd {
    public static func end(_ pids: [Int32], grace: Double = 5, step: Double = 0.25,
                           signal: @Sendable (Int32, Int32) -> Void = { _ = kill($0, $1) },
                           alive: @Sendable (Int32) -> Bool = { kill($0, 0) == 0 },
                           sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async {
        for pid in pids { signal(pid, SIGCONT); signal(pid, SIGTERM) }
        var waited = 0.0
        while waited < grace, pids.contains(where: alive) {
            await sleep(step)
            waited += step
        }
        for pid in pids where alive(pid) { signal(pid, SIGKILL) }
    }
}

public enum InGameOutcome: Equatable, Sendable { case none, resume, quit }

/// The in-game panel (C5): A or B resumes the game; X asks before quitting, then A quits and B goes back.
public struct InGameMenu: Equatable, Sendable {
    public private(set) var confirming = false

    public init() {}

    public mutating func press(_ button: CouchButton) -> InGameOutcome {
        if confirming {
            if button == .a { return .quit }
            if button == .b { confirming = false }
            return .none
        }
        switch button {
        case .a, .b: return .resume
        case .x: confirming = true; return .none
        default: return .none
        }
    }
}

/// A window as macOS's window list reports it (kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds).
public struct GameWindow: Equatable, Sendable {
    public var pid: Int32, layer: Int, width: Double, height: Double
    public init(pid: Int32, layer: Int, width: Double, height: Double) {
        self.pid = pid; self.layer = layer; self.width = width; self.height = height
    }
}

public enum CouchAction: Equatable, Sendable {
    case play, resume, quitAndPlay(running: String), why, hide, unhide, back, menu, none
    case tryAgain, installAnyway, playExisting(String), removeInstall     // on a game on its way in
}

public enum Couch {
    /// A and B on a game on its way in (spec D12): Try Again or Remove on a failure, Install Anyway on the one firm no,
    /// Play on a game that is already there.
    public static func installAction(_ stage: InstallStage, button: CouchButton) -> CouchAction {
        switch (stage, button) {
        case (.failed, .a): return .tryAgain
        case (.confirm, .a): return .installAnyway
        case (.alreadyInLibrary(let id), .a): return .playExisting(id)
        case (.failed, .b), (.confirm, .b), (.alreadyInLibrary, .b): return .removeInstall
        default: return .none
        }
    }

    /// What A does on `selected` while `running` (a LibraryGame id) is running. While `starting` is on its way
    /// (started, not running yet), A waits: another press would start a second game.
    public static func primary(selected: String, running: String?, starting: String? = nil) -> CouchAction {
        guard let running else { return starting == nil ? .play : .none }
        return running == selected ? .resume : .quitAndPlay(running: running)
    }

    /// Whether one of `pids` has a window to show: a normal one (layer 0) at least 640 by 360, not Wine's
    /// menu bar strip or the small window it opens first.
    public static func hasGameWindow(pids: [Int32], windows: [GameWindow]) -> Bool {
        windows.contains { pids.contains($0.pid) && $0.layer == 0 && $0.width >= 640 && $0.height >= 360 }
    }

    /// What Y does: hides the selected game (asking first), or puts a hidden one back (Show Hidden Games is
    /// on), the only way back from the couch.
    public static func secondary(hidden: Bool) -> CouchAction { hidden ? .unhide : .hide }
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

    /// Library games' processes left stopped by something other than this run of Stepover's panel (`ours`): a
    /// previous Stepover that crashed or was force quit with the panel up. Continuing them is the way out.
    public static func strayPaused(_ games: [LibraryGame], processes: [RunningPrograms.Process],
                                   isStopped: (Int32) -> Bool, ours: [Int32]) -> [Int32] {
        games.flatMap { self.processes(of: $0, in: processes) }.map(\.pid).filter { !ours.contains($0) && isStopped($0) }
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
            // or a bare-named exe that's in the game's folder: a launcher there can start the game by name
            return inBottle.filter { process in
                if process.windowsPath.lowercased().hasPrefix(folder) { return true }
                guard RunningPrograms.isWindowsPath(process.windowsPath) == false,
                      let file = WindowsPath.toMac(app.windowsFolder + "\\" + process.windowsPath, bottle: game.bottle) else { return false }
                return FileManager.default.fileExists(atPath: file.path)
            }
        case .program(let program):
            // its exe, or anything from its folder: a game can hand off to a launcher there and exit
            let exe = WindowsPath.fileName(program.exe).lowercased()
            let folder = String(program.exe.lowercased().dropLast(exe.count))
            return inBottle.filter { $0.exeName == exe || (folder.count > 3 && $0.windowsPath.lowercased().hasPrefix(folder)) }
        case .steamClient, .install:
            return []
        }
    }
}
