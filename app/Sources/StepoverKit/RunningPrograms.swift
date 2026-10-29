import Darwin
import Foundation

/// Windows programs running in each bottle. Wine names a process after its Windows path (argv[0] is
/// C:\...\game.exe) and keeps its Unix working directory inside the bottle, which is how a process is
/// matched to its bottle: Wine overwrites the process's environment, so WINEPREFIX can't be read.
public enum RunningPrograms {
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var windowsPath: String
        public var cwd: String

        public init(pid: Int32, windowsPath: String, cwd: String) {
            self.pid = pid; self.windowsPath = windowsPath; self.cwd = cwd
        }

        public var exeName: String { WindowsPath.fileName(windowsPath).lowercased() }
        /// Wine's own processes (explorer, services, winedevice...) live in C:\windows.
        public var isSystem: Bool { windowsPath.lowercased().hasPrefix("c:\\windows\\") }
    }

    /// Every process whose name is a Windows path, with its working directory.
    public static func processes() -> [Process] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(found, 0))).compactMap { pid in
            guard pid > 0, let name = firstArgument(pid), isProgramName(name), let cwd = workingDirectory(pid) else { return nil }
            return Process(pid: pid, windowsPath: name, cwd: cwd)
        }
    }

    /// The processes running in the bottle at `bottlePath`.
    public static func inBottle(_ processes: [Process], bottlePath: String) -> [Process] {
        let root = URL(fileURLWithPath: bottlePath).resolvingSymlinksInPath().path + "/"
        return processes.filter { $0.cwd.hasPrefix(root) }
    }

    /// Whether the process is stopped (SIGSTOP), as a game is while the in-game panel is up.
    public static func isStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    /// A Windows path, or a bare exe name: a program started by name has no path (Rockstar's launcher starts
    /// "RDR2.exe"). Its working directory still places it in a bottle.
    static func isProgramName(_ s: String) -> Bool {
        isWindowsPath(s) || (!s.contains("/") && s.lowercased().hasSuffix(".exe"))
    }

    static func isWindowsPath(_ s: String) -> Bool {
        let c = Array(s.utf8.prefix(3))
        return c.count == 3 && (65...90 ~= c[0] || 97...122 ~= c[0]) && c[1] == UInt8(ascii: ":") && c[2] == UInt8(ascii: "\\")
    }

    /// Every argument from KERN_PROCARGS2. A Wine process's are its Windows command line, one argument each (an Inno
    /// installer's setup.tmp shows its loader's /SL5="..." here); empty when the process is gone.
    public static func arguments(_ pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    /// The process's CPU time so far (user and system), in seconds; 0 when it's gone.
    public static func cpuSeconds(_ pid: Int32) -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.pti_total_user + info.pti_total_system)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// argv[0] from KERN_PROCARGS2: argc, the exec path, padding, then the arguments.
    static func firstArgument(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var j = i
        while j < size && buf[j] != 0 { j += 1 }
        return j > i ? String(decoding: buf[i..<j], as: UTF8.self) : nil
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }
}
