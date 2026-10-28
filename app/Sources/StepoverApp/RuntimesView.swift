import StepoverKit
import SwiftUI

/// Wine Runtimes (File menu): every installed runtime, its state in the runtime list, the bottles that use it,
/// and Remove for the ones Stepover doesn't keep (the two newest that aren't pulled).
struct RuntimesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: Runtime?

    var body: some View {
        let installed = Runtime.installed()
        let names = installed.map(\.name)
        let pulled = store.index.pulled
        let kept = RuntimeCatalog.kept(installed: names, pulled: pulled)
        VStack(alignment: .leading, spacing: 12) {
            Text("Wine Runtimes").font(.title2.bold())
            Text("New runtimes install next to the ones you have, and Stepover keeps the two newest. Each bottle picks its Wine version on its page.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(installed.reversed(), id: \.name) { runtime in
                row(runtime, names: names, pulled: pulled, kept: kept)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        // the window's own alert can't show while this sheet is up
        .alert("Stepover", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") { store.alert = nil }
        } message: { Text(store.alert ?? "") }
        .confirmationDialog("Remove \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { runtime in
            Button("Remove \(runtime.name)", role: .destructive) { store.removeRuntime(runtime) }
        } message: { runtime in
            let users = RuntimeCatalog.users(of: runtime.name, bottles: store.runtimeUsers)
            let next = Runtime.choose(pinned: nil, lastUsed: nil, installed: names.filter { $0 != runtime.name },
                                      pulled: pulled, preferred: nil)
            Text(RuntimeCatalog.removalMessage(users: users, runtime: runtime.name, next: next))
        }
    }

    private func row(_ runtime: Runtime, names: [String], pulled: Set<String>, kept: Set<String>) -> some View {
        let entry = store.index.runtimes.first { $0.name == runtime.name }
        let users = RuntimeCatalog.users(of: runtime.name, bottles: store.runtimeUsers)
        let good = Runtime.choose(pinned: nil, lastUsed: nil, installed: names, pulled: pulled, preferred: nil)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(runtime.name).bold()
                    Text(label(entry)).foregroundStyle(.secondary)
                }
                Text(runtime.summary).font(.caption).foregroundStyle(.secondary)
                if let note = entry?.note { Text(note).font(.caption) }
                Text(users.isEmpty ? "Not used by any bottle" : "Used by \(users.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pulled.contains(runtime.name), !users.isEmpty, let good, good != runtime.name {
                Button("Switch Its Bottles to \(good)") { store.switchBottles(off: runtime.name) }
            }
            if !kept.contains(runtime.name) {
                Button("Remove") {
                    if let reason = RuntimeCatalog.refusal(runtime.name, bottles: store.bottles) { store.alert = reason }
                    else if users.isEmpty { store.removeRuntime(runtime) } else { confirm = runtime }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func label(_ entry: RuntimeManifest?) -> String {
        guard let entry else { return "not in the runtime list" }
        switch entry.status ?? .current {
        case .current: return "current"
        case .available: return "available"
        case .pulled: return "pulled"
        }
    }
}

/// The bottle page's Wine version: Newest (follows new runtimes) or one installed runtime, with what that means.
struct WineVersionPicker: View {
    @EnvironmentObject var store: Store
    let bottle: Bottle

    var body: some View {
        let config = store.config(bottle)
        let installed = Runtime.installed().map(\.name)
        let pulled = store.index.pulled
        let newest = Runtime.choose(pinned: nil, lastUsed: bottle.lastRuntime, installed: installed, pulled: pulled,
                                    preferred: Paths.defaultRuntimeName)
        let state = RuntimeCatalog.state(pinned: config.runtime, resolved: bottle.runtime(config)?.name,
                                         installed: installed, index: store.index)
        Picker("Wine version", selection: Binding(get: { config.runtime ?? "" },
                                                  set: { value in store.update(bottle) { $0.runtime = value.isEmpty ? nil : value } })) {
            Text("Newest (\(newest ?? "none installed"))").tag("")
            ForEach(installed.reversed(), id: \.self) { name in
                Text(pulled.contains(name) ? "\(name) (pulled)" : name).tag(name)
            }
            if let pin = config.runtime, !installed.contains(pin) { Text("\(pin) (not installed)").tag(pin) }
        }
        switch state {
        case .pinned(let name, let newer?):
            HStack {
                Text("On \(name); \(newer) is newer.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use Newest") { store.useNewest(bottle) }
            }
        case .missingPin(let name, let using):
            Text("\(name) isn't installed; using \(using ?? "no runtime").").font(.caption).foregroundStyle(.secondary)
        case .onPulled(let name, let note, let suggested):
            HStack {
                Text("\(name) was pulled\(note.map { ": \($0)" } ?? ".")").font(.caption)
                Spacer()
                if let suggested { Button("Switch to \(suggested)") { store.useNewest(bottle) } }
            }
        default:
            EmptyView()
        }
    }
}
