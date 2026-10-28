import AppKit
import StepoverKit
import SwiftUI

@main
struct StepoverApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Stepover") {
            RootView()
                .environmentObject(store)
                .onAppear { appDelegate.store = store }
                .frame(minWidth: 880, minHeight: 560)
                .alert("Stepover", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
                    Button("OK") { store.alert = nil }
                } message: { Text(store.alert ?? "") }
        }
        .commands {
            CommandGroup(before: .toolbar) {
                Button("Library") { store.setView(bottles: false) }.keyboardShortcut("1")
                Button("Bottles") { store.setView(bottles: true) }.keyboardShortcut("2")
                Toggle("Show Hidden Games", isOn: Binding(get: { store.showHidden }, set: { store.showHidden = $0 }))
                Toggle("Look Up Unknown Games on Steam", isOn: Binding(get: { store.lookUpUnknown }, set: { store.lookUpUnknown = $0 }))
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("Reload Bottles") { store.reload(); store.refreshIndex() }.keyboardShortcut("r")
                Button("Wine Runtimes…") { store.refreshIndex(); store.showRuntimes = true }
            }
            CommandMenu("Fixes") {
                Button("Update Fixes") { store.updateFixes() }
                Button("Open My Fixes Folder") { store.openFixesFolder() }
                Button("Fix Sources…") { store.showFixSources = true }
                Divider()
                Button("How to Add a Fix") { store.openFixGuide() }
            }
            CommandGroup(replacing: .help) {
                Button("Licenses and Notices") { store.openLicenses() }
                Button("Games List Credits") {
                    store.alert = store.gamesCredits.isEmpty ? "No games list yet."
                        : (["What Stepover knows about games comes from:"] + store.gamesCredits).joined(separator: "\n")
                }
                Button("Stepover Source Code") { store.openSource() }
                if let link = Bundle.main.object(forInfoDictionaryKey: "StepoverSponsorURL") as? String,
                   let url = URL(string: link) {
                    Button("Support Stepover") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// The Library, or today's bottle pages (View > Bottles).
struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.showBottles { BottlesView() } else { LibraryView() }
        }
        .sheet(isPresented: $store.showFixSources) { FixSourcesSheet() }
        .sheet(isPresented: $store.showRuntimes) { RuntimesView() }
    }
}

struct BottlesView: View {
    @EnvironmentObject var store: Store
    @State private var showImport = false
    @State private var showCreate = false

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Section("Bottles") {
                    ForEach(store.bottles) { bottle in
                        HStack {
                            Image(systemName: "wineglass")
                            Text(bottle.name)
                            Spacer()
                            if store.running.contains(bottle.id) {
                                Circle().fill(.green).frame(width: 8, height: 8).help("Running")
                            }
                        }
                        .tag(bottle.id)
                    }
                }
                if let update = store.runtimeUpdate {
                    Section("Wine Runtime") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wine runtime \(update.name) is available").font(.headline)
                            Text("A \(ByteCountFormatter.string(fromByteCount: update.size, countStyle: .file)) download, installed next to the one you have. Bottles set to Newest use it; you can pick another Wine version for any bottle.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let progress = store.runtimeProgress {
                                ProgressView(value: progress)
                            } else {
                                Button("Download") { store.installRuntime() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button { store.setView(bottles: false) } label: { Label("Library", systemImage: "square.grid.2x2") }
                    .help("Back to your games")
                Menu {
                    Button("New Bottle…") { showCreate = true }
                    if store.hasCrossOver { Button("Import from CrossOver…") { showImport = true } }
                } label: { Label("Add Bottle", systemImage: "plus") }
                .disabled(!store.runtimeReady)
            }
        } detail: {
            if !store.runtimeReady {
                RuntimeSetupView()
            } else if let bottle = store.selected {
                BottleView(bottle: bottle).id(bottle.id)
            } else {
                ContentUnavailableView {
                    Label("No bottles yet", systemImage: "wineglass")
                } description: {
                    Text("A bottle is a Windows folder for one or more games. Make one, then install your game into it.")
                } actions: {
                    Button("New Bottle…") { showCreate = true }.buttonStyle(.borderedProminent)
                    if store.hasCrossOver { Button("Import from CrossOver…") { showImport = true } }
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportSheet() }
        .sheet(isPresented: $showCreate) { CreateSheet() }
    }
}

struct BottleView: View {
    @EnvironmentObject var store: Store
    let bottle: Bottle
    @State private var otherVerb = ""

    private func installOther() {
        let verbs = otherVerb.split(separator: " ").map(String.init)
        guard !verbs.isEmpty else { return }
        store.installComponents(verbs, into: bottle)
        otherVerb = ""
    }

    var config: BottleConfig { store.config(bottle) }
    var running: Bool { store.running.contains(bottle.id) }
    var busy: Bool { store.busy.contains(bottle.id) }

    var body: some View {
        Form {
            Section {
                ForEach(config.programs) { program in ProgramRow(bottle: bottle, program: program) }
                HStack {
                    Button { store.installProgram(into: bottle) } label: {
                        Label("Install Windows Program…", systemImage: "square.and.arrow.down")
                    }
                    Button { store.addProgram(to: bottle) } label: { Label("Add Program…", systemImage: "plus.circle") }
                    if busy { ProgressView().controlSize(.small).padding(.leading, 6) }
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            } header: {
                Text("Programs")
            } footer: {
                Text("Each program gets its own graphics backend; Stepover's compat plug-in applies it inside Wine, also when a launcher starts the game.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bottle") {
                WineVersionPicker(bottle: bottle)
                Picker("Default graphics", selection: Binding(get: { config.graphics }, set: { value in store.update(bottle) { $0.graphics = value } })) {
                    ForEach(Backend.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: Binding(get: { config.msync }, set: { value in store.update(bottle) { $0.msync = value } })) {
                    Text("MSync")
                    Text("Faster thread sync. Off for games that hang with it (Hi-Fi Rush's intro).")
                }
                let display = store.display[bottle.id] ?? (false, 96)
                Toggle(isOn: Binding(get: { display.highRes }, set: { store.setDisplay(bottle, highRes: $0, dpi: display.dpi) })) {
                    Text("High Resolution Mode")
                    Text("Full Retina pixels instead of points (games see 3456×2234 instead of 1728×1117).")
                }
                Picker("Windows scaling", selection: Binding(get: { display.dpi }, set: { store.setDisplay(bottle, highRes: display.highRes, dpi: $0) })) {
                    Text("100% (96 dpi)").tag(96)
                    Text("150% (144 dpi)").tag(144)
                    Text("200% (192 dpi)").tag(192)
                    if ![96, 144, 192].contains(display.dpi) { Text("\(display.dpi) dpi").tag(display.dpi) }
                }
                .disabled(busy)
            }

            Section {
                if WindowsSetup.winetricks == nil {
                    Text("Needs winetricks: run `brew install winetricks` in Terminal.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Menu("Install Component") {
                            ForEach(WindowsSetup.commonComponents) { c in
                                Button("\(c.title): \(c.detail)") { store.installComponents([c.verb], into: bottle) }
                            }
                        }
                        .fixedSize()
                        TextField("other winetricks verb", text: $otherVerb)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(installOther)
                        Button("Install", action: installOther).disabled(otherVerb.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(busy)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Windows runtimes a game may ask for, installed with winetricks. Downloads come from Microsoft and the other vendors.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Apply fixes from the fix list", isOn: Binding(get: { config.fixes },
                                                                      set: { value in store.update(bottle) { $0.fixes = value } }))
                if config.fixes {
                    let candidates = store.fixCandidates[bottle.id] ?? []
                    if candidates.isEmpty {
                        Text("No fixes match the programs or Steam games in this bottle.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.fix.id) { matched in
                        Toggle(isOn: Binding(get: { !config.disabledFixes.contains(matched.fix.id) },
                                             set: { store.setFix(matched.fix.id, on: $0, in: bottle) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(matched.fix.name)
                                let changes = fixChanges(matched)
                                if !changes.isEmpty { Text(changes).font(.caption).foregroundStyle(.secondary) }
                                if let notes = matched.fix.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .help(matched.fix.id)
                    }
                }
            } header: {
                Text("Fixes")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixes come from the official list, sources you add and your own fixes folder (Fixes menu). Each game gets one fix, and yours wins. Components and registry values install the next time Stepover starts a program here.")
                    if let runtime = bottle.runtime(config), let format = runtime.compatFormat, config.fixes {
                        let disabled = Set(config.disabledFixes)
                        ForEach((store.fixCandidates[bottle.id] ?? []).filter { !disabled.contains($0.fix.id) && $0.neededCompatFormat > format },
                                id: \.fix.id) { matched in
                            Text("\(runtime.name) can't apply all of \(matched.fix.name); pick a newer Wine version.")
                        }
                    }
                    if !store.fixNotes.isEmpty {
                        Text("\(store.fixNotes.count) fix item(s) were skipped or left out for safety; `stepover fixes` lists them.")
                            .help(store.fixNotes.prefix(20).joined(separator: "\n"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Environment") {
                EnvironmentEditor(env: config.env) { env in store.update(bottle) { $0.env = env } }
            }

            Section("Tools") {
                HStack {
                    Button("Open C: Drive") { NSWorkspace.shared.open(bottle.cDrive) }
                    Button("Wine Settings") { store.runTool(["winecfg"], in: bottle) }
                    Button("Registry Editor") { store.runTool(["regedit"], in: bottle) }
                    Button("Task Manager") { store.runTool(["taskmgr"], in: bottle) }
                    Button("Run .exe…") { runExe() }
                }
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(bottle.logURL) }
                    Button("Show Bottle in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bottle.url]) }
                    Spacer()
                    Button("Stop Everything", role: .destructive) { store.stop(bottle) }.disabled(!running || busy)
                }
            }

            Section("About this bottle") {
                LabeledContent("Status", value: running ? "Running" : "Idle")
                LabeledContent("Wine", value: bottle.runtime(config).map { "\($0.name): \($0.summary)" } ?? "No runtime installed")
                if let origin = config.origin { LabeledContent("Origin", value: origin) }
                LabeledContent("Folder", value: bottle.url.path).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .navigationSubtitle(running ? "Running" : "")
    }

    private func runExe() { store.runExe(in: bottle) }
}

struct ProgramRow: View {
    @EnvironmentObject var store: Store
    let bottle: Bottle
    let program: Program

    var config: BottleConfig { store.config(bottle) }
    var backend: Backend { config.backend(for: program) }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = store.icon(for: program, in: bottle) { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.name).font(.headline)
                Text(program.exe).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Graphics", selection: Binding(get: { backend }, set: { value in set { $0.graphics = value } })) {
                ForEach(Backend.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .help(backend.summary)
            if backend == .d3dmetal {
                Toggle("MetalFX", isOn: Binding(get: { program.env["D3DM_ENABLE_METALFX"] == "1" },
                                                set: { on in set { $0.env["D3DM_ENABLE_METALFX"] = on ? "1" : nil } }))
                    .toggleStyle(.checkbox)
                    .help("Turns the game's DLSS option into Apple's MetalFX upscaling")
            }
            Button { store.play(program, in: bottle) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("Pick Graphics Automatically") { autoPick() }
                Button("Make Mac App") { store.makeApp(program, in: bottle) }
                Button("Show in Finder") {
                    if let url = WindowsPath.toMac(program.exe, bottle: bottle) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Save Settings as My Fix") { store.saveFix(program, in: bottle) }
                Button("Share Fix on GitHub…") { store.shareFix(program, in: bottle) }
                Button("Report How It Ran…") { store.report(program, in: bottle) }
                Divider()
                Button("Remove from List", role: .destructive) {
                    store.update(bottle) { $0.programs.removeAll { $0.name == program.name } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
        }
        .padding(.vertical, 2)
    }

    private func set(_ change: @escaping (inout Program) -> Void) {
        store.update(bottle) { config in
            if let i = config.programs.firstIndex(where: { $0.name == program.name }) { change(&config.programs[i]) }
        }
    }

    private func autoPick() {
        guard let exe = WindowsPath.toMac(program.exe, bottle: bottle) else { return }
        let pick = GraphicsPicker.pick(exe: exe)
        set { p in p.graphics = pick.backend; p.env.merge(pick.env) { _, new in new } }
        store.alert = "\(program.name): \(pick.backend.label). \(pick.reason)."
    }
}

/// One line about what a fix changes, for the bottle's Fixes list; its notes go on their own line.
func fixChanges(_ matched: MatchedFix) -> String {
    let fix = matched.fix
    var parts: [String] = []
    if let graphics = fix.graphics, let backend = Backend(rawValue: graphics) { parts.append(backend.label) }
    if !fix.components.isEmpty { parts.append(fix.components.joined(separator: ", ")) }
    if !fix.dlls.isEmpty { parts.append("DLLs: " + fix.dlls.keys.sorted().joined(separator: ", ")) }
    if !fix.env.isEmpty { parts.append(fix.env.keys.sorted().joined(separator: ", ")) }
    if !fix.args.isEmpty { parts.append(fix.args.joined(separator: " ")) }
    if !fix.registry.isEmpty { parts.append("\(fix.registry.count) registry value(s)") }
    if let version = fix.windowsVersion { parts.append("Windows version: \(version)") }
    return parts.joined(separator: " · ")
}

struct FixSourcesSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var sources = FixLibrary.addedSources()
    @State private var name = ""
    @State private var url = ""
    @State private var trusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix Sources").font(.title2.bold())
            Text("Anyone can publish a fix list: a GitHub repository with a fixes folder (github:owner/repo) or a link to a JSON file. Flagged items (ones that could run commands) are left out unless you trust the source. Your own fixes folder always applies as written.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                HStack { Text("official").bold(); Text(FixLibrary.official.url).foregroundStyle(.secondary) }
                ForEach(sources, id: \.name) { source in
                    HStack {
                        Text(source.name).bold()
                        Text(source.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Toggle("Trusted", isOn: Binding(get: { source.trusted }, set: { value in
                            if let i = sources.firstIndex(of: source) { sources[i].trusted = value }
                        })).toggleStyle(.checkbox)
                        Button(role: .destructive) { sources.removeAll { $0 == source } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 140)
            HStack {
                TextField("Name", text: $name).frame(width: 120)
                TextField("github:owner/repo or https://…/fixes.json", text: $url)
                Toggle("Trusted", isOn: $trusted).toggleStyle(.checkbox)
                Button("Add") {
                    sources.removeAll { $0.name == name }
                    sources.append(FixSource(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces), trusted: trusted))
                    name = ""; url = ""; trusted = false
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save and Update") {
                    do { try FixLibrary.setAddedSources(sources); store.updateFixes(); dismiss() }
                    catch { store.alert = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

struct EnvironmentEditor: View {
    let env: [String: String]
    let save: ([String: String]) -> Void
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        ForEach(env.keys.sorted(), id: \.self) { key in
            HStack {
                Text(key).font(.system(.body, design: .monospaced))
                Spacer()
                Text(env[key] ?? "").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                Button { var e = env; e[key] = nil; save(e) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        HStack {
            TextField("NAME", text: $newKey).font(.system(.body, design: .monospaced))
            TextField("value", text: $newValue).font(.system(.body, design: .monospaced))
            Button("Add") {
                var e = env
                e[newKey.trimmingCharacters(in: .whitespaces)] = newValue
                save(e)
                newKey = ""; newValue = ""
            }
            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

struct RuntimeSetupView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wineglass").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("One more download").font(.title2.bold())
            if let manifest = store.manifest {
                Text("Stepover runs Windows games with a Wine runtime built from CodeWeavers' CrossOver source, plus Apple's D3DMetal, DXMT and DXVK. It is a one-time \(ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file)) download.")
                    .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
                if let progress = store.runtimeProgress {
                    ProgressView(value: progress).frame(width: 320)
                    Text(progress < 1 ? "Downloading… \(Int(progress * 100))%" : "Unpacking…").foregroundStyle(.secondary)
                } else {
                    Button("Download Wine Runtime") { store.installRuntime() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                Text("Apple's D3DMetal is free for non-commercial use on Apple hardware; licenses are under Help.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !store.index.runtimes.isEmpty {
                Text("The Wine runtime needs a newer Stepover. Update Stepover (in Terminal: brew upgrade --cask stepover), then open it again.")
                    .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
            } else {
                Text("This build has no runtime download. Build one with ~/.local/src/stepover/runtime, or run `stepover runtime install --from <file>`.")
                    .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
            }
        }
        .padding(40)
    }
}

struct ImportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from CrossOver").font(.title2.bold())
            Text("Makes an instant copy (no extra disk space until files change). CrossOver's bottle stays exactly as it is.")
                .foregroundStyle(.secondary)
            List(Importer.crossOverBottles(), id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    if item.imported { Text("Imported").foregroundStyle(.secondary) }
                    else { Button("Import") { store.importCrossOver(item.name); dismiss() } }
                }
            }
            .frame(minHeight: 180)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct CreateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Bottle").font(.title2.bold())
            Text("A 64-bit Windows 10 bottle with MSync on and D3DMetal as the default.").foregroundStyle(.secondary)
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { store.create(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
