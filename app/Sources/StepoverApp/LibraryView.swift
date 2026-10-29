import AppKit
import StepoverKit
import SwiftUI

/// The first screen: your games as cover art, with the two plain answers (will it play on this Mac, does it
/// work with a controller) and why. The selected game (else the last played) fills the hero at the top,
/// tinted by its own cover. Spec: docs/superpowers/specs/2026-10-28-library-design.md.
struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var showImport = false
    @State private var showCreate = false

    private var games: [LibraryGame] {
        store.library.filter { store.showHidden || !store.hidden.contains($0.id) }
    }

    var body: some View {
        Group {
            if games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Drag a game's installer or folder here")
                } actions: {
                    VStack(spacing: 12) {
                        HStack {
                            Button("Add Game from Installer or Folder…") { store.chooseToAdd() }.buttonStyle(.borderedProminent)
                            Button("New Bottle…") { showCreate = true }
                            if store.hasCrossOver { Button("Import from CrossOver…") { showImport = true } }
                        }
                        .disabled(!store.runtimeReady)
                        .help(store.runtimeReady ? "" : "Available once what games need has downloaded")
                        RuntimeStatus()
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if let hero = games.first(where: { $0.id == selection }) ?? games.first {
                        HeroView(game: hero).id(hero.id)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("Your games").font(.title3.weight(.semibold))
                                Text("Last played first").font(.callout).foregroundStyle(.secondary)
                                Spacer(minLength: 16)
                                RuntimeStatus()
                                ControllerStatus()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 168), spacing: 22, alignment: .top)],
                                      alignment: .leading, spacing: 26) {
                                ForEach(games) { game in
                                    GameTile(game: game, selected: (selection ?? games.first?.id) == game.id) { selection = game.id }
                                }
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 22)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .onChange(of: store.justAdded) { _, id in if let id { selection = id } }
        .sheet(isPresented: $showImport) { ImportSheet() }
        .sheet(isPresented: $showCreate) { CreateSheet() }
    }
}

/// Which controller Stepover sees: plain status text, not a control.
struct ControllerStatus: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: store.controllerName == nil ? "gamecontroller" : "gamecontroller.fill")
            if let name = store.controllerName {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(name) connected")
            } else {
                Text("No controller")
            }
        }
        .font(.callout)
        .foregroundStyle(store.controllerName == nil ? .secondary : .primary)
        .fixedSize()
        .help(store.controllerName == nil ? "Connect a controller to see it here" : "Stepover sees this controller")
    }
}

/// One line about what games need to run, in plain words (beside the controller status).
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
    /// The tone's text color for this appearance (StepoverKit picks values that read at 4.5:1 on their pill).
    func color(_ scheme: ColorScheme) -> Color {
        let c = rgb(dark: scheme == .dark)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

/// A verdict as a tinted capsule: the word always travels with its color.
struct VerdictPill: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let tone: TileTone
    var large = false
    var scale: CGFloat = 1   // couch mode reads from across the room

    var body: some View {
        let color = tone.color(scheme)
        HStack(spacing: (large ? 7 : 5) * scale) {
            Circle().fill(color).frame(width: (large ? 8 : 6) * scale, height: (large ? 8 : 6) * scale)
            Text(text).lineLimit(large ? 2 : 1)
        }
        .font(.system(size: (large ? 13 : 10.5) * scale, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, (large ? 11 : 8) * scale).padding(.vertical, (large ? 6 : 3) * scale)
        .background(color.opacity(tone.pillAlpha), in: Capsule())
    }
}

/// A 2:3 cover clipped to its corners: Steam's art, else a cover made from the game's icon and name.
struct CoverView: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let id = game.steamAppID, let image = store.art[id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    PlaceholderCover(game: game)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Two muted tones picked from the name (the same every launch), the program's icon and the title.
struct PlaceholderCover: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        let hue = Self.hue(game.name)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.38, brightness: 0.42),
                                    Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.18)],
                           startPoint: .top, endPoint: .bottom)
            VStack {
                Group {
                    if game.isSteamClient {
                        Image(systemName: "bag").font(.system(size: 38, weight: .light))
                    } else if let icon = store.icon(for: game.launch, in: game.bottle) {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64).shadow(radius: 8, y: 3)
                    } else {
                        Image(systemName: "gamecontroller").font(.system(size: 38, weight: .light))
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(game.name)
                .font(.system(size: 17, weight: .bold).width(.expanded))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(12)
        }
    }

    static func hue(_ name: String) -> Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 360) / 360
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
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                CoverView(game: game)
                    .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                    .scaleEffect(hovering ? 1.02 : 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    if game.isSteamClient {
                        Text("Your Steam games show up here").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VerdictPill(text: verdict.kind.short, tone: verdict.kind.tone)
                    }
                    if let job = game.install { InstallLine(job: job) }
                    if let note = game.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if store.hidden.contains(game.id) { Text("Hidden").font(.caption2).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.playGame(game) })
        .contextMenu {
            if let job = game.install {
                if job.isFailed { Button("Try Again") { store.tryAgain(job) } }
                Button("Details") { store.showInstallLog(job) }
                Button("Remove") { store.removeInstall(job) }.disabled(job.stage.isActive)
            } else {
                gameMenu
            }
        }
    }

    @ViewBuilder private var gameMenu: some View {
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

    private func folder(of game: LibraryGame) -> URL {
        switch game.kind {
        case .steamGame(let app): return app.folder
        case .program(let program), .steamClient(let program):
            return WindowsPath.toMac(program.exe, bottle: game.bottle)?.deletingLastPathComponent() ?? game.bottle.cDrive
        case .install:
            return game.bottle.cDrive
        }
    }
}

struct PlayButton: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        Button { store.playGame(game) } label: {
            Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 14).padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!store.runtimeReady)
        .help(waitReason ?? "Play \(game.name)")
    }

    private var waitReason: String? {
        if store.runtimeReady { return nil }
        if let progress = store.runtimeProgress { return "Getting ready to play (\(Int(progress * 100))%)" }
        if store.runtimeFailed { return "Couldn't get what games need yet; press Retry" }
        return "Getting ready to play"
    }
}

/// The selected game, large: its cover blurred into a backdrop tinted by the cover's own color, the title,
/// both answers, Play, and what the answer is based on. Always dark, so the text reads on any cover.
struct HeroView: View {
    @EnvironmentObject var store: Store
    let game: LibraryGame

    var body: some View {
        let verdict = Verdicts.play(game.entry)
        let image = game.steamAppID.flatMap { store.art[$0] }
        let tint = game.steamAppID.flatMap { store.tint[$0] }.map(Color.init(nsColor:))
            ?? Color(hue: PlaceholderCover.hue(game.name), saturation: 0.4, brightness: 0.35)
        HStack(alignment: .top, spacing: 26) {
            CoverView(game: game).frame(width: 156).shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 14) {
                Text(game.name)
                    .font(.system(size: 34, weight: .bold).width(.expanded))
                    .lineLimit(2).minimumScaleFactor(0.6)
                if game.isSteamClient {
                    Text("Open Steam to buy, install and update games. Games you install show up here by themselves.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        VerdictPill(text: verdict.headline, tone: verdict.kind.tone, large: true)
                        if let controller = Verdicts.controller(game.entry) {
                            Label(controller.rawValue, systemImage: "gamecontroller")
                                .font(.callout.weight(.medium)).lineLimit(2)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                    }
                }
                if let job = game.install {
                    InstallControls(job: job)
                } else {
                    if let note = game.note { Text(note).font(.callout.weight(.medium)) }
                    HStack(spacing: 10) {
                        PlayButton(game: game).keyboardShortcut(.defaultAction)   // Return plays the selected game
                        Button("Settings") { store.openSettings(game) }.controlSize(.large)
                    }
                    if let offer = store.trashOffers[game.bottle.name] {
                        HStack(spacing: 10) {
                            Text(offer).font(.callout.weight(.medium))
                            Button("Move to Trash") { store.moveSourceToTrash(bottle: game.bottle.name) }
                            Button("Keep") { store.keepSource(bottle: game.bottle.name) }
                        }
                    }
                }
                if !game.isSteamClient && !(verdict.extra.isEmpty && verdict.reasons.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(verdict.extra, id: \.self) { Text($0).font(.callout.weight(.semibold)) }
                        if !verdict.reasons.isEmpty {
                            Text("Based on").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                            ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                                (Text(reason.text) + Text(reason.source.map { "  " + $0 } ?? "").foregroundColor(.secondary))
                                    .font(.callout).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                tint
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().blur(radius: 60).opacity(0.5)
                }
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// What a game on its way in is doing, under its tile: plain words, and a spinner while Stepover works on it.
struct InstallLine: View {
    @Environment(\.colorScheme) private var scheme
    let job: InstallJob

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if job.stage.isActive { ProgressView().controlSize(.mini) }
            Text(job.stage.text)
                .font(.caption)
                .foregroundStyle(job.isFailed ? TileTone.caution.color(scheme) : .secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The hero's buttons for a game on its way in (spec D3, D9).
struct InstallControls: View {
    @EnvironmentObject var store: Store
    let job: InstallJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if job.stage.isActive { ProgressView().controlSize(.small) }
                Text(job.stage.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                switch job.stage {
                case .confirm:
                    Button("Install Anyway") { store.installAnyway(job) }.buttonStyle(.borderedProminent).controlSize(.large)
                    remove
                case .alreadyInLibrary(let id):
                    Button("Play") { store.playExisting(id) }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Install Again") { store.installAnyway(job) }.controlSize(.large)
                    remove
                case .failed(.noGame):
                    Button("Choose the Game…") { store.chooseGame(job) }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Try Again") { store.tryAgain(job) }.controlSize(.large)
                    remove
                    details
                case .failed:
                    Button("Try Again") { store.tryAgain(job) }.buttonStyle(.borderedProminent).controlSize(.large)
                    remove
                    details
                case .waiting:
                    remove
                default:
                    details
                }
            }
        }
    }

    private var remove: some View { Button("Remove") { store.removeInstall(job) }.controlSize(.large) }
    private var details: some View { Button("Details") { store.showInstallLog(job) }.controlSize(.large) }
}
