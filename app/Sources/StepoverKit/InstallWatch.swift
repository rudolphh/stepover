import Foundation

/// What the watcher sees every couple of seconds while an installer runs.
public struct InstallSample: Sendable {
    public var time: Double                         // seconds since the install started
    public var processes: [RunningPrograms.Process] // the bottle's processes
    public var cpuSeconds: Double                   // their CPU time so far, all together
    public var written: Int64                       // bytes in the game's install folder
    public var free: Int64                          // free bytes on the bottles' disk
    public var sourceExists: Bool                   // the dropped folder is still there

    public init(time: Double, processes: [RunningPrograms.Process], cpuSeconds: Double, written: Int64, free: Int64, sourceExists: Bool) {
        self.time = time; self.processes = processes; self.cpuSeconds = cpuSeconds
        self.written = written; self.free = free; self.sourceExists = sourceExists
    }
}

public enum InstallAction: Equatable, Sendable {
    case end([Int32])                                   // hang-prone steps: SIGKILL
    case largeAddressFix(pid: Int32, windowsPath: String)   // spec Appendix A, for this Inno setup.tmp
    case pause([Int32]), resume([Int32])                // the disk floor (D11)
    case stuck                                          // nothing written for too long (D5)
    case sourceGone                                     // the dropped folder went away (an unplugged drive)
}

/// The rules for watching an installer that runs unattended (spec D5, D11, Appendix A). Pure: the caller samples the
/// bottle and carries out the actions.
public struct InstallWatch: Sendable {
    public static let floor: Int64 = 5_000_000_000, resumeAt: Int64 = 10_000_000_000
    public static let idleLimit = 600.0, busyLimit = 1_800.0, idleCPU = 0.02
    /// Steps installers start that hang under Wine; Stepover supplies what they would install (D6).
    public static let hangProne = ["dxwebsetup.exe", "dxsetup.exe", "vc_redist*.exe", "vcredist*.exe", "quicksfv.exe",
                                   "ue4prereqsetup*.exe", "ueprereqsetup*.exe"]

    let kind: InstallerKind
    let visible: Bool
    var ended = Set<Int32>(), fixed = Set<Int32>()
    var paused: [Int32]?
    var growth: (time: Double, written: Int64, cpu: Double)?
    var stuckSaid = false, goneSaid = false

    public init(kind: InstallerKind, visible: Bool) { self.kind = kind; self.visible = visible }

    public var isPaused: Bool { paused != nil }

    public mutating func step(_ sample: InstallSample) -> [InstallAction] {
        if !sample.sourceExists {
            if goneSaid { return [] }
            goneSaid = true
            return [.sourceGone]
        }
        var actions: [InstallAction] = []
        let hung = sample.processes.filter { !ended.contains($0.pid) && Self.isHangProne($0.exeName) }.map(\.pid).sorted()
        if !hung.isEmpty { ended.formUnion(hung); actions.append(.end(hung)) }

        if kind == .inno {
            for p in sample.processes where !fixed.contains(p.pid) && p.exeName == "setup.tmp"
                && p.windowsPath.lowercased().range(of: #"\\is-[^\\]*\.tmp\\setup\.tmp$"#, options: .regularExpression) != nil {
                fixed.insert(p.pid)
                actions.append(.largeAddressFix(pid: p.pid, windowsPath: p.windowsPath))
            }
        }

        if let pids = paused {
            if sample.free >= Self.resumeAt {
                paused = nil
                growth = (sample.time, sample.written, sample.cpuSeconds)   // time spent paused doesn't count
                actions.append(.resume(pids))
            }
            return actions
        }
        if sample.free < Self.floor {
            let pids = sample.processes.filter { !$0.isSystem }.map(\.pid).sorted()
            paused = pids
            actions.append(.pause(pids))
            return actions
        }

        if let last = growth, sample.written <= last.written {
            let flat = sample.time - last.time
            let rate = flat > 0 ? (sample.cpuSeconds - last.cpu) / flat : 0
            if !visible, !stuckSaid, flat >= Self.busyLimit || (flat >= Self.idleLimit && rate < Self.idleCPU) {
                stuckSaid = true
                actions.append(.stuck)
            }
        } else {
            growth = (sample.time, sample.written, sample.cpuSeconds)
        }
        return actions
    }

    static func isHangProne(_ exeName: String) -> Bool {
        let name = exeName.lowercased()
        return hangProne.contains { pattern in
            guard let star = pattern.firstIndex(of: "*") else { return name == pattern }
            return name.hasPrefix(pattern[..<star]) && name.hasSuffix(pattern[pattern.index(after: star)...])
        }
    }
}
