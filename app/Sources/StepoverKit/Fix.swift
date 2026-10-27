import Foundation

/// A fix that applies in a bottle (its game was found there), and where its settings go.
public struct MatchedFix: Hashable, Sendable {
    public let fix: Fix
    /// Lowercased program file names that get its graphics, environment and DLL settings.
    public let programs: [String]
    /// Lowercased program file names its launch arguments are appended to.
    public let argPrograms: [String]

    public init(fix: Fix, programs: [String], argPrograms: [String]) {
        self.fix = fix; self.programs = programs; self.argPrograms = argPrograms
    }
}

/// A per-game fix: settings Stepover applies when the game runs. Data only; the format and the
/// safety rules are documented in fixes/README.md.
public struct Fix: Codable, Hashable, Sendable {
    public struct Match: Codable, Hashable, Sendable {
        public var steam: [Int]
        public var exe: [String]
        enum CodingKeys: String, CodingKey { case steam, exe }
        public init(steam: [Int] = [], exe: [String] = []) { self.steam = steam; self.exe = exe }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steam = try c.decodeIfPresent([Int].self, forKey: .steam) ?? []
            exe = try c.decodeIfPresent([String].self, forKey: .exe) ?? []
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !steam.isEmpty { try c.encode(steam, forKey: .steam) }
            if !exe.isEmpty { try c.encode(exe, forKey: .exe) }
        }
    }

    public struct RegistryValue: Codable, Hashable, Sendable {
        public var key: String
        public var name: String
        public var type: String
        public var value: String
        public init(key: String, name: String, type: String, value: String) {
            self.key = key; self.name = name; self.type = type; self.value = value
        }
    }

    public var name: String
    public var match: Match
    public var graphics: String?
    public var env: [String: String] = [:]
    public var args: [String] = []
    public var dlls: [String: String] = [:]
    public var components: [String] = []
    public var registry: [RegistryValue] = []
    /// Windows version the matched programs see (Wine's per-program AppDefaults), e.g. "win7".
    public var windowsVersion: String?
    public var notes: String?
    public var source: String?
    /// Where the fix was loaded from ("<source>/<file>"); set by FixLibrary, not part of the file.
    public var id = ""

    enum CodingKeys: String, CodingKey {
        case name, match, graphics, env, args, dlls, components, registry, windowsVersion, notes, source
    }

    public init(name: String, match: Match) { self.name = name; self.match = match }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        match = try c.decodeIfPresent(Match.self, forKey: .match) ?? Match()
        graphics = try c.decodeIfPresent(String.self, forKey: .graphics)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        dlls = try c.decodeIfPresent([String: String].self, forKey: .dlls) ?? [:]
        components = try c.decodeIfPresent([String].self, forKey: .components) ?? []
        registry = try c.decodeIfPresent([RegistryValue].self, forKey: .registry) ?? []
        windowsVersion = try c.decodeIfPresent(String.self, forKey: .windowsVersion)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    /// Writes only the fields in use, so saved fixes stay short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(match, forKey: .match)
        try c.encodeIfPresent(graphics, forKey: .graphics)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        if !dlls.isEmpty { try c.encode(dlls, forKey: .dlls) }
        if !components.isEmpty { try c.encode(components, forKey: .components) }
        if !registry.isEmpty { try c.encode(registry, forKey: .registry) }
        try c.encodeIfPresent(windowsVersion, forKey: .windowsVersion)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(source, forKey: .source)
    }

    /// A fix file holds one fix or an array of them.
    public static func decodeFile(_ data: Data) throws -> [Fix] {
        if let many = try? JSONDecoder().decode([Fix].self, from: data) { return many }
        return [try JSONDecoder().decode(Fix.self, from: data)]
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    // MARK: validity

    public static let dllOrders = ["native", "builtin", "native,builtin", "builtin,native", "disabled"]
    public static let registryTypes = ["REG_SZ", "REG_DWORD"]
    /// Wine's names for Windows versions (winecfg / AppDefaults "Version").
    public static let windowsVersions = ["win11", "win10", "win81", "win8", "win7", "win2008r2", "win2008", "vista",
                                         "win2003", "winxp64", "winxp", "win2k", "nt40", "winme", "win98", "win95"]
    /// winetricks verbs that replace core Windows parts for the whole bottle; bottles are shared
    /// (Steam and its games), so fixes can't ask for them.
    static let wholeBottleComponents: Set = ["ole32", "oleaut32"]

    /// What makes the fix unusable as data; a fix with problems is not applied at all.
    public func problems() -> [String] {
        var out: [String] = []
        let label = name.isEmpty ? "fix" : name
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("the fix needs a name") }
        if match.steam.isEmpty && match.exe.isEmpty { out.append("\(label): needs a match (Steam app IDs or exe names)") }
        for id in match.steam where id <= 0 { out.append("\(label): Steam app ID \(id) isn't valid") }
        for exe in match.exe where !Self.isProgramName(exe) {
            out.append("\(label): \"\(exe)\" must be a program file name ending in .exe (no folders, brackets, =, ; or #)")
        }
        if let graphics, Backend(rawValue: graphics) == nil {
            out.append("\(label): graphics \"\(graphics)\" isn't one of \(Backend.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            if !Self.isName(key) { out.append("\(label): environment name \"\(key)\" isn't valid") }
            if value.contains(where: \.isNewline) { out.append("\(label): environment value for \(key) has a line break") }
        }
        for arg in args where arg.isEmpty || arg.contains(where: \.isNewline) {
            out.append("\(label): argument \"\(arg)\" is empty or has a line break")
        }
        for (dll, order) in dlls.sorted(by: { $0.key < $1.key }) {
            if dll.isEmpty || !dll.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) {
                out.append("\(label): DLL name \"\(dll)\" isn't valid")
            }
            if !Self.dllOrders.contains(order) {
                out.append("\(label): DLL order \"\(order)\" for \(dll) isn't one of \(Self.dllOrders.joined(separator: " | "))")
            }
        }
        for verb in components {
            if verb.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) == nil {
                // includes winetricks settings (sound=alsa, ...): they change the whole bottle
                out.append("\(label): component \"\(verb)\" isn't a winetricks verb name (settings like name=value change the whole bottle)")
            } else if Self.windowsVersions.contains(verb) {
                out.append("\(label): component \"\(verb)\" changes the whole bottle's Windows version; use \"windowsVersion\": \"\(verb)\"")
            } else if Self.wholeBottleComponents.contains(verb) {
                out.append("\(label): component \"\(verb)\" replaces a core Windows part for the whole (shared) bottle")
            }
        }
        if let windowsVersion, !Self.windowsVersions.contains(windowsVersion) {
            out.append("\(label): windowsVersion \"\(windowsVersion)\" isn't one of \(Self.windowsVersions.joined(separator: ", "))")
        }
        for item in registry {
            let key = Self.normalizedKey(item.key)
            if !key.hasPrefix("HKCU\\") && !key.hasPrefix("HKLM\\") {
                out.append("\(label): registry key \"\(item.key)\" must start with HKCU\\ or HKLM\\")
            }
            if !Self.registryTypes.contains(item.type) {
                out.append("\(label): registry type \"\(item.type)\" isn't one of \(Self.registryTypes.joined(separator: ", "))")
            } else if item.type == "REG_DWORD" && Self.dword(item.value) == nil {
                out.append("\(label): \(item.name) needs a number (decimal or 0x hex), not \"\(item.value)\"")
            }
            if [item.key, item.name, item.value].contains(where: { !Self.isOneLine($0) }) {
                out.append("\(label): registry value \(item.name) has a line break or control character")
            }
        }
        return out
    }

    // MARK: safety (items a person should look at before they reach everyone; see fixes/README.md)

    static let flaggedEnvPrefixes = ["DYLD_", "LD_", "STEPOVER_"]
    static let flaggedEnvNames: Set = ["WINEPREFIX", "WINESERVER", "WINELOADER", "WINEDLLPATH", "PATH", "HOME",
                                       "COMSPEC", "PATHEXT"]
    /// Programs that Steam, launchers or Wine itself use in every bottle: a fix naming one changes
    /// them for everyone, so a person looks first.
    static let sharedPrograms: Set = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe",
        "explorer.exe", "cmd.exe", "conhost.exe", "rundll32.exe", "regedit.exe", "services.exe", "svchost.exe",
        "winedevice.exe", "plugplay.exe", "rpcss.exe", "wineboot.exe", "start.exe", "msiexec.exe", "winecfg.exe",
        "notepad.exe", "launcher.exe", "start_protected_game.exe", "setup.exe", "install.exe", "unins000.exe",
        "uplay.exe", "upc.exe", "ubisoftconnect.exe", "epicgameslauncher.exe", "eadesktop.exe", "origin.exe",
        "battle.net.exe", "galaxyclient.exe", "rockstarlauncher.exe", "launcherpatcher.exe",
    ]

    static func isFlagged(env name: String) -> Bool {
        let upper = name.uppercased()
        return flaggedEnvNames.contains(upper) || flaggedEnvPrefixes.contains { upper.hasPrefix($0) }
    }

    /// Registry: numbers can't be commands, text can. Free: number (REG_DWORD) values under a
    /// vendor's or game's key (HKCU\Software\<Vendor> or HKLM\Software\<Vendor>), and any value under
    /// the few Wine keys that only hold settings. Flagged: text values elsewhere; everything under
    /// Microsoft, Classes, Policies, System, Control Panel or Environment (Run, Winlogon, Image File
    /// Execution Options, AeDebug, AppInit_DLLs, COM and file-type commands, services...); and the
    /// rest of Software\Wine (WineBrowser and Mailers hold Mac commands Wine runs for web and mail links).
    static func isFlagged(registry item: RegistryValue) -> Bool {
        var parts = normalizedKey(item.key).lowercased().split(separator: "\\").map(String.init)
        guard parts.count >= 3, ["hkcu", "hklm"].contains(parts[0]), parts[1] == "software" else { return true }
        if parts[2] == "wow6432node" { parts.remove(at: 2) }
        guard parts.count >= 3, !["microsoft", "classes", "policies"].contains(parts[2]) else { return true }
        if parts[2] == "wine" { return !isWineSetting(Array(parts.dropFirst(3)), name: item.name.lowercased()) }
        return item.type != "REG_DWORD"
    }

    static let wineSettingKeys: Set = ["direct3d", "directinput", "directsound", "mac driver", "x11 driver", "dlloverrides"]

    /// Keys under Software\Wine that only hold settings: Direct3D, DirectInput, DirectSound, the Mac
    /// and X11 drivers, DLL overrides and font replacements, and those per program under
    /// AppDefaults\<exe> (plus its Version value).
    static func isWineSetting(_ path: [String], name: String) -> Bool {
        if path.count == 1 { return wineSettingKeys.contains(path[0]) }
        if path == ["fonts", "replacements"] { return true }
        if path.first == "appdefaults" {
            if path.count == 2 { return name == "version" }
            if path.count == 3 { return wineSettingKeys.contains(path[2]) }
        }
        return false
    }

    /// Items a person should look at first, with what each one is.
    public func flagged() -> [String] {
        env.keys.sorted().filter(Self.isFlagged(env:)).map { "\(name): environment variable \($0)" }
            + registry.filter(Self.isFlagged(registry:)).map { "\(name): registry \($0.key)\\\($0.name) (\($0.type))" }
            + match.exe.filter { Self.sharedPrograms.contains($0.lowercased()) }.map { "\(name): applies to \($0), which other games and Steam share" }
    }

    /// The fix without its flagged items (how fixes from untrusted sources are applied).
    public func withoutFlagged() -> Fix {
        var safe = self
        safe.env = env.filter { !Self.isFlagged(env: $0.key) }
        safe.registry = registry.filter { !Self.isFlagged(registry: $0) }
        safe.match.exe = match.exe.filter { !Self.sharedPrograms.contains($0.lowercased()) }
        return safe
    }

    // MARK: helpers

    /// A `dlls` entry in WINEDLLOVERRIDES syntax ("ddraw=n,b"; "x=" disables).
    public static func wineOverride(_ dll: String, _ order: String) -> String {
        let short = order == "disabled" ? "" : order.split(separator: ",").map { $0 == "native" ? "n" : "b" }.joined(separator: ",")
        return "\(dll)=\(short)"
    }

    static func normalizedKey(_ key: String) -> String {
        if key.uppercased().hasPrefix("HKEY_CURRENT_USER\\") { return "HKCU\\" + key.dropFirst("HKEY_CURRENT_USER\\".count) }
        if key.uppercased().hasPrefix("HKEY_LOCAL_MACHINE\\") { return "HKLM\\" + key.dropFirst("HKEY_LOCAL_MACHINE\\".count) }
        return key
    }

    static func dword(_ value: String) -> UInt32? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return v.hasPrefix("0x") ? UInt32(v.dropFirst(2), radix: 16) : UInt32(v)
    }

    /// A bare program file name that is safe as an INI section name in stepover-compat.conf.
    public static func isProgramName(_ s: String) -> Bool {
        s.lowercased().hasSuffix(".exe") && s.count > 4
            && !s.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false || "/\\[]=;#".contains($0) })
    }

    static func isOneLine(_ s: String) -> Bool { !s.contains { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) } }

    static func isName(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }
}
