import Foundation

extension Launcher {
    /// The fixes that apply in the bottle now: the fix list against its programs and Steam games.
    public static func matchedFixes(_ bottle: Bottle, config: BottleConfig) -> [MatchedFix] {
        guard config.fixes else { return [] }
        return config.matchedFixes(FixLibrary.load().fixes, programs: programNames(bottle, config: config),
                                   steamApps: SteamLibrary.apps(in: bottle))
    }

    /// Lowercased program file names found in the bottle: its programs, and the programs in their
    /// folders (a launcher's game usually sits next to it).
    public static func programNames(_ bottle: Bottle, config: BottleConfig) -> Set<String> {
        let exes = config.programs.compactMap { WindowsPath.toMac($0.exe, bottle: bottle.url) }
        return Set(programFiles(near: exes)).union(config.programs.map { $0.exeName.asciiLowercased })
    }

    /// Program files (lowercased names) in the folders of `exes`, a few levels deep.
    static func programFiles(near exes: [URL]) -> [String] {
        let folders = Set(exes.map { $0.deletingLastPathComponent().standardizedFileURL })
        let names = folders.flatMap { SteamApp.programs(in: $0, depth: 3) }.map { $0.lastPathComponent.asciiLowercased }
        return Array(Set(names)).sorted()
    }

    /// Installs what the fixes of games found in the bottle need, once: winetricks components
    /// (winetricks.log in the bottle records what is in; a failed one is recorded and not retried
    /// automatically), registry values and per-program Windows versions (recorded in stepover.json,
    /// and removed again when their fix stops applying). Skipped while the bottle runs, so for games
    /// started by Steam it happens when Stepover starts Steam. Failures are logged, not fatal: a
    /// missing component never stops a game from starting.
    public static func applyFixes(_ bottle: Bottle) {
        var config = bottle.loadConfig()
        let present = matchedFixes(bottle, config: config)
        let installed = installedComponents(bottle)
        var missing: [String] = []
        for verb in present.flatMap(\.fix.components)
        where !installed.contains(verb) && !missing.contains(verb) && !config.failedComponents.contains(verb) {
            missing.append(verb)
        }
        let wanted = registryEntries(present)
        let stale = config.appliedRegistry.filter { !wanted.keys.contains($0) }
        // a value another fix still wants is not deleted but written again (with what that fix wants)
        let wantedValues = Set(wanted.values.map(valueKey))
        let staleValues = Set(stale.compactMap(recordedValue).map(valueKey))
        let toSet = wanted.filter { !config.appliedRegistry.contains($0.key) || staleValues.contains(valueKey($0.value)) }
        guard !missing.isEmpty || !stale.isEmpty || !toSet.isEmpty else { return }

        // Wine's server stays up a few seconds after the last program exits; only a bottle still
        // in use after that counts as running (and then this waits for the next start).
        for _ in 0..<12 where bottle.isRunning { Thread.sleep(forTimeInterval: 0.5) }
        guard !bottle.isRunning else { return }

        if !missing.isEmpty {
            let names = present.filter { !Set($0.fix.components).isDisjoint(with: missing) }.map(\.fix.name)
            appendLog(bottle, "fixes for \(names.joined(separator: ", ")) need \(missing.joined(separator: " "))")
            var ran = false
            do {
                let status = try WindowsSetup.installComponents(missing, into: bottle)
                ran = true
                if status != 0 { appendLog(bottle, "winetricks exited with \(status)") }
            } catch {
                appendLog(bottle, "couldn't install components: \(error.localizedDescription)")
            }
            // only a real winetricks run counts as a failure (not winetricks missing)
            let failed = ran ? missing.filter { !installedComponents(bottle).contains($0) } : []
            if !failed.isEmpty {
                appendLog(bottle, "\(failed.joined(separator: " ")) didn't install; not retrying automatically (Components retries)")
                config = bottle.loadConfig()
                config.failedComponents += failed
                try? bottle.save(config, fixes: present)
            }
        }

        guard !stale.isEmpty || !toSet.isEmpty else { return }
        var patch = RegistryPatch()
        var deleted = 0
        for entry in stale {
            // the fix is off or its game is gone; values another fix wants are set again below
            guard let item = recordedValue(entry), !wantedValues.contains(valueKey(item)) else { continue }
            patch.set(longKey(Fix.normalizedKey(item.key)), item.name, .delete)
            deleted += 1
        }
        for (_, item) in toSet.sorted(by: { $0.key < $1.key }) {
            patch.set(longKey(Fix.normalizedKey(item.key)), item.name,
                      item.type == "REG_DWORD" ? .dword(Fix.dword(item.value) ?? 0) : .string(item.value))
        }
        do {
            try importRegistry(patch, into: bottle)
            config = bottle.loadConfig()  // importRegistry's session may have updated it (setup stamp)
            let kept = config.appliedRegistry.filter { !stale.contains($0) }
            config.appliedRegistry = kept + toSet.keys.filter { !kept.contains($0) }.sorted()
            try bottle.save(config, fixes: present)
            appendLog(bottle, "fixes set \(toSet.count) and removed \(deleted) registry value(s)")
        } catch {
            appendLog(bottle, "couldn't update registry values from fixes: \(error.localizedDescription)")
        }
    }

    /// The registry values the fixes want, keyed by their record in stepover.json (fix id, key, name,
    /// type and value joined by U+001F, which fixes can't contain), so a value is removed again when
    /// its fix stops applying. A windowsVersion becomes Wine's per-program
    /// AppDefaults\<file name>\Version for the game's main programs.
    static func registryEntries(_ fixes: [MatchedFix]) -> [String: Fix.RegistryValue] {
        var out: [String: Fix.RegistryValue] = [:]
        for matched in fixes {
            var items = matched.fix.registry
            if let version = matched.fix.windowsVersion {
                let names = Set(matched.argPrograms.map { $0.split(separator: "\\").last.map(String.init) ?? $0 })
                for exe in names.sorted() where !Fix.sharedPrograms.contains(exe) {
                    items.append(Fix.RegistryValue(key: "HKCU\\Software\\Wine\\AppDefaults\\\(exe)", name: "Version",
                                                   type: "REG_SZ", value: version))
                }
            }
            for item in items {
                out[[matched.fix.id, Fix.normalizedKey(item.key), item.name, item.type, item.value].joined(separator: "\u{1F}")] = item
            }
        }
        return out
    }

    /// A record from registryEntries back as a value; records in an older format give nil (dropped).
    static func recordedValue(_ record: String) -> Fix.RegistryValue? {
        let parts = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else { return nil }
        return Fix.RegistryValue(key: parts[1], name: parts[2], type: parts[3], value: parts[4])
    }

    /// One registry value's identity: its key and name.
    static func valueKey(_ item: Fix.RegistryValue) -> String {
        Fix.normalizedKey(item.key).asciiLowercased + "\u{1F}" + item.name.asciiLowercased
    }

    /// Verbs winetricks has installed in the bottle, from its own log.
    static func installedComponents(_ bottle: Bottle) -> Set<String> {
        guard let text = try? String(contentsOf: bottle.url.appendingPathComponent("winetricks.log"), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// regedit's REGEDIT4 files want full hive names.
    static func longKey(_ key: String) -> String {
        if key.hasPrefix("HKCU\\") { return "HKEY_CURRENT_USER\\" + key.dropFirst(5) }
        if key.hasPrefix("HKLM\\") { return "HKEY_LOCAL_MACHINE\\" + key.dropFirst(5) }
        return key
    }
}
