import AppKit
import CoreImage
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
                    Text("Install a Windows game, or bring your games over from CrossOver.")
                } actions: {
                    Button("New Bottle…") { showCreate = true }.buttonStyle(.borderedProminent)
                    if store.hasCrossOver { Button("Import from CrossOver…") { showImport = true } }
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

/// A verdict as a tinted capsule: the word always travels with its color.
struct VerdictPill: View {
    let text: String
    let tone: TileTone
    var large = false

    var body: some View {
        HStack(spacing: large ? 7 : 5) {
            Circle().fill(tone.color).frame(width: large ? 8 : 6, height: large ? 8 : 6)
            Text(text).lineLimit(large ? 2 : 1)
        }
        .font(large ? .callout.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, large ? 11 : 8).padding(.vertical, large ? 6 : 3)
        .background(tone.color.opacity(tone == .unknown ? 0.12 : 0.16), in: Capsule())
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
        return "Couldn't get what games need yet; Retry is in the toolbar"
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
                HStack(spacing: 10) {
                    PlayButton(game: game)
                    Button("Settings") { store.openSettings(game) }.controlSize(.large)
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

extension NSImage {
    /// The image's average color (CoreImage's area average), for the hero's tint.
    var averageColor: NSColor? {
        guard let tiff = tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
