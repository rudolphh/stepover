import AppKit
import StepoverKit
import SwiftUI

@main
struct StepoverApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Stepover") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 880, minHeight: 560)
                .alert("Stepover", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
                    Button("OK") { store.alert = nil }
                } message: { Text(store.alert ?? "") }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Bottles") { store.reload() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("Licenses and Notices") { store.openLicenses() }
                Button("Stepover Source Code") { store.openSource() }
            }
        }
    }
}

struct ContentView: View {
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
                if store.runtimeUpdate, let manifest = store.manifest {
                    Section("Wine Runtime") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Update available").font(.headline)
                            Text("A \(ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file)) download. Quit running games first.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let progress = store.runtimeProgress {
                                ProgressView(value: progress)
                            } else {
                                Button("Update Runtime") { store.installRuntime() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
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
                LabeledContent("Wine", value: bottle.runtime(config)?.summary ?? "No runtime installed")
                if let origin = config.origin { LabeledContent("Origin", value: origin) }
                LabeledContent("Folder", value: bottle.url.path).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .navigationSubtitle(running ? "Running" : "")
    }

    private func runExe() {
        let panel = NSOpenPanel()
        panel.directoryURL = bottle.cDrive
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!, .init(filenameExtension: "msi")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let windows = WindowsPath.toWindows(url, bottle: bottle)
        store.runTool(url.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", windows] : [windows], in: bottle)
    }
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
