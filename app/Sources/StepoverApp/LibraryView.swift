import AppKit
import StepoverKit
import SwiftUI

/// The first screen: your games as cover art, with the two plain answers (will it play on this Mac, does it
/// work with a controller) and why. Spec: docs/superpowers/specs/2026-10-28-library-design.md.
struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var showImport = false
    @State private var showCreate = false

    private var games: [LibraryGame] {
        store.library.filter { store.showHidden || !store.hidden.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Install a Windows game, or bring your games over from CrossOver.")
                } actions: {
                    Button("New Bottle…") { showCreate = true }.buttonStyle(.borderedProminent)
                    if store.hasCrossOver { Button("Import from CrossOver…") { showImport = true } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Your games").font(.title2.bold())
                            Text("Last played first").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)],
                                  alignment: .leading, spacing: 22) {
                            ForEach(games) { game in
                                GameTile(game: game, selected: selection == game.id) { selection = game.id }
                            }
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity)
                if let game = games.first(where: { $0.id == selection }) {
                    Divider()
                    GameDetail(game: game).frame(width: 340)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RuntimeStatus() }
            ToolbarItem(placement: .primaryAction) {
                Label(store.controllerName.map { "\($0) connected" } ?? "No controller", systemImage: "gamecontroller")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(store.controllerName == nil ? .secondary : .primary)
                    .help(store.controllerName == nil ? "Connect a controller to see it here" : "Stepover sees this controller")
            }
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showImport) { ImportSheet() }
        .sheet(isPresented: $showCreate) { CreateSheet() }
    }
}

/// The toolbar's one line about what games need to run, in plain words.
struct RuntimeStatus: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if !store.runtimeReady, let progress = store.runtimeProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 80)
                Text("Getting ready to play: \(Int(progress * 100))%").font(.callout)
            }
        } else if !store.runtimeReady, store.runtimeFailed {
            HStack(spacing: 6) {
                Text("Couldn't get what games need").font(.callout)
                Button("Retry") { store.installRuntime() }
            }
        } else if store.runtimeUpdate != nil {
            HStack(spacing: 6) {
                Text("A compatibility update is ready").font(.callout)
                if let progress = store.runtimeProgress { ProgressView(value: progress).frame(width: 80) }
                else { Button("Download") { store.installRuntime() } }
            }
        }
    }
}

extension TileTone {
    var color: Color {
        switch self {
        case .good: return .green
        case .maybe: return .blue
        case .caution: return .orange
        case .bad: return .red
        case .mac: return .purple
        case .unknown: return .secondary
        }
    }
}

struct GameTile: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let verdict = Verdicts.play(game.entry)
        ZStack(alignment: .top) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 5) {
                    GameArtView(game: game)
                        .frame(height: 230)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: selected ? 3 : 0))
                    Text(game.name).font(.headline).lineLimit(2)
                    if game.isSteamClient {
                        Text("Your Steam games show up here").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("● " + verdict.kind.short).font(.caption).foregroundStyle(verdict.kind.tone.color)
                        if let controller = Verdicts.controller(game.entry) {
                            Text(controller.short).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if store.hidden.contains(game.id) { Text("Hidden").font(.caption2).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.playGame(game) })
            if hovering || selected {
                PlayButton(game: game).padding(.top, 182)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play") { store.playGame(game) }.disabled(!store.runtimeReady)
            Button("Settings") { store.openSettings(game) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder(of: game)]) }
            Divider()
            if store.hidden.contains(game.id) {
                Button("Show in Library") { store.setHidden(game, false) }
            } else {
                Button("Hide from Library") { store.setHidden(game, true) }
            }
        }
    }

    private func folder(of game: LibraryGame) -> URL {
        switch game.kind {
        case .steamGame(let app): return app.folder
        case .program(let program), .steamClient(let program):
            return WindowsPath.toMac(program.exe, bottle: game.bottle)?.deletingLastPathComponent() ?? game.bottle.cDrive
        }
    }
}

struct PlayButton: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        Button { store.playGame(game) } label: {
            Label("Play", systemImage: "play.fill").padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.runtimeReady)
        .help(waitReason ?? "Play \(game.name)")
    }

    private var waitReason: String? {
        if store.runtimeReady { return nil }
        if let progress = store.runtimeProgress { return "Getting ready to play (\(Int(progress * 100))%)" }
        return "Couldn't get what games need yet; Retry is in the toolbar"
    }
}

/// Cover art, else the program's own icon on a tinted tile with its name.
struct GameArtView: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        if let id = game.steamAppID, let image = store.art[id] {
            Image(nsImage: image).resizable().aspectRatio(2 / 3, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .overlay {
                    VStack(spacing: 10) {
                        if game.isSteamClient {
                            Image(systemName: "bag").font(.system(size: 40)).foregroundStyle(.secondary)
                        } else if let icon = store.icon(for: game.launch, in: game.bottle) {
                            Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                        } else {
                            Image(systemName: "gamecontroller").font(.system(size: 40)).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

struct GameDetail: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        let verdict = Verdicts.play(game.entry)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    GameArtView(game: game).frame(width: 96, height: 144)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(game.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            PlayButton(game: game)
                            Button("Settings") { store.openSettings(game) }
                        }
                    }
                }
                if game.isSteamClient {
                    Text("Open Steam to buy, install and update games. Games you install show up here by themselves.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    section("Will it play?") {
                        Text("● " + verdict.headline).font(.headline).foregroundStyle(verdict.kind.tone.color)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(verdict.extra, id: \.self) { line in
                            Text(line).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                            (Text(reason.text) + Text(reason.source.map { "  " + $0 } ?? "").foregroundColor(.secondary))
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    section("Controller") {
                        Text(Verdicts.controller(game.entry)?.rawValue ?? "Not known yet").font(.headline)
                    }
                }
            }
            .padding(22)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content()
        }
    }
}
