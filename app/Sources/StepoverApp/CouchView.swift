import AppKit
import StepoverKit
import SwiftUI

/// Couch mode: the Library full screen for a TV across the room, driven by a controller (or the keyboard:
/// arrows, Return = A, Escape = B, Space = X, Delete = Y, Tab = Menu). Never a Mac alert while it's up.
/// Spec: docs/superpowers/specs/2026-10-28-couch-mode-design.md.
struct CouchView: View {
    @EnvironmentObject var store: Store
    @StateObject private var input = ControllerBridge()
    @State private var focus: String?   // the selected game's id: playing a game moves it, and focus goes along
    @State private var place = 0        // where focus was, for when its game is hidden
    @State private var showWhy = false
    @State private var menu: Int?
    @State private var confirm: Confirm?
    @State private var enteredFullScreen = false
    @State private var screen: NSScreen?   // the screen couch mode is on
    @FocusState private var focused: Bool

    enum Confirm: Equatable {
        case hide(LibraryGame)
        case quitAndPlay(running: LibraryGame, next: LibraryGame)
    }

    private var games: [LibraryGame] { store.library.filter { store.showHidden || !store.hidden.contains($0.id) } }
    private var index: Int { CouchRow(ids: games.map(\.id), focus: focus, fallback: place).index }
    private var selected: LibraryGame? { games.indices.contains(index) ? games[index] : games.first }

    private func select(_ at: Int) {
        guard games.indices.contains(at) else { return }
        focus = games[at].id
        place = at
    }

    /// The Menu's choices; `detail` shows under a choice while it's highlighted, for ones the title doesn't explain.
    private var menuItems: [(title: String, detail: String?, action: () -> Void)] {
        var items: [(String, String?, () -> Void)] = []
        if let screen, !isMain(screen) { items.append(("Make This the Main Display", nil, { store.makeMainDisplay(screen); self.screen = screen })) }
        items.append(("Leave Couch Mode", nil, { store.couchMode = false }))
        items.append((store.showHidden ? "Hide Hidden Games" : "Show Hidden Games", nil, { store.showHidden.toggle() }))
        if let running = store.runningGame { items.append(("Stop Everything", nil, { store.quitGame(running) })) }
        if !store.runtimeReady && store.runtimeFailed { items.append(("Retry Download", nil, { store.installRuntime() })) }
        items.append((store.openAtLogin ? "Open at Login: On" : "Open at Login: Off",
                      "Opens Stepover when you log in to this Mac, so couch mode is ready without the mouse.",
                      { store.setOpenAtLogin(!store.openAtLogin) }))
        return items
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                statusLine.padding(.horizontal, 72).padding(.top, 40)
                Spacer(minLength: 24)
                if let game = selected { hero(game).padding(.horizontal, 72) }
                Spacer(minLength: 24)
                rowView
                hints.padding(.horizontal, 72).padding(.vertical, 28)
            }
            if showWhy, let game = selected { whyPanel(game) }
            if let menu { menuPanel(menu) }
            if let confirm { confirmPanel(confirm) }
            if let message = store.alert { messagePanel(message) }
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space, .delete, .tab]) { press in
            let map: [KeyEquivalent: CouchButton] = [.leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
                                                     .return: .a, .escape: .b, .space: .x, .delete: .y, .tab: .menu]
            if let button = map[press.key] { handle(button) }
            return .handled
        }
        .onAppear {
            focused = true
            input.onPress = { handle($0) }
            input.start()
            store.updateRunningGame()
            if let ended = store.endedGame { focus = ended.id }
            setFullScreen(true)
        }
        .onDisappear {
            input.stop()
            setFullScreen(false)
        }
        .onChange(of: store.endedGame) { _, ended in
            if let ended { focus = ended.id }
        }
    }

    // MARK: input

    private func handle(_ button: CouchButton) {
        if store.alert != nil { if button == .b || button == .a { store.alert = nil }; return }
        if let pending = confirm {
            if button == .a { perform(pending) }
            if button == .a || button == .b { confirm = nil }
            return
        }
        if let at = menu {
            switch button {
            case .up: menu = max(at - 1, 0)
            case .down: menu = min(at + 1, menuItems.count - 1)
            case .a: menu = nil; menuItems[at].action()
            case .b, .menu: menu = nil
            default: break
            }
            return
        }
        if showWhy { if button == .b || button == .x { showWhy = false }; return }
        var row = CouchRow(count: games.count, index: index)
        switch button {
        case .left: row.move(-1); select(row.index)
        case .right: row.move(1); select(row.index)
        case .a: if let game = selected { primary(game) }
        case .x: showWhy = selected != nil
        case .y: if let game = selected { confirm = .hide(game) }
        case .menu: menu = 0
        default: break
        }
    }

    private func primary(_ game: LibraryGame) {
        switch Couch.primary(selected: game.id, running: store.runningGame?.id, starting: store.starting?.id) {
        case .play: store.playGame(game)
        case .resume: if let running = store.runningGame { store.resume(running) }
        case .quitAndPlay: if let running = store.runningGame { confirm = .quitAndPlay(running: running, next: game) }
        default: break
        }
    }

    private func perform(_ pending: Confirm) {
        switch pending {
        case .hide(let game): place = index; store.setHidden(game, true)   // focus lands on the game that takes its place
        case .quitAndPlay(let running, let next): store.quitGame(running) { store.playGame(next) }
        }
    }

    /// The main display is the one at the global origin, where games go full screen.
    private func isMain(_ screen: NSScreen) -> Bool {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
    }

    private func setFullScreen(_ on: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
            screen = window.screen
            let isFull = window.styleMask.contains(.fullScreen)
            if on, !isFull { window.toggleFullScreen(nil); enteredFullScreen = true }
            if !on, isFull, enteredFullScreen { window.toggleFullScreen(nil); enteredFullScreen = false }
        }
    }

    // MARK: pieces

    private var backdrop: some View {
        Color(nsColor: selected.flatMap { $0.steamAppID }.flatMap { store.tint[$0] } ?? NSColor(white: 0.12, alpha: 1))
            .overlay {
                // an overlay never sizes what it sits on: a portrait cover filling the screen as a ZStack layer
                // made the whole screen taller than the display and pushed the row and hints off it
                if let id = selected?.steamAppID, let image = store.art[id] {
                    Image(nsImage: image).resizable().scaledToFill().blur(radius: 70).opacity(0.55)
                }
            }
            .overlay { LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom) }
        .ignoresSafeArea()
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var statusLine: some View {
        HStack {
            if !store.runtimeReady, let progress = store.runtimeProgress {
                Text("Getting ready to play: \(Int(progress * 100))%")
            } else if !store.runtimeReady, store.runtimeFailed {
                Text("Couldn't get what games need. Menu > Retry Download")
            } else if let screen, !isMain(screen) {
                Text("Games open on your other screen. Menu > Make This the Main Display")
            }
            Spacer()
            Label(store.controllerName.map { "\($0) connected" } ?? "No controller", systemImage: "gamecontroller")
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func hero(_ game: LibraryGame) -> some View {
        let verdict = Verdicts.play(game.entry)
        return VStack(alignment: .leading, spacing: 22) {
            Text(game.name)
                .font(.system(size: 72, weight: .bold).width(.expanded))
                .lineLimit(2).minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            if game.isSteamClient {
                Text("Your Steam games show up here by themselves.").font(.system(size: 26)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    VerdictPill(text: verdict.headline, tone: verdict.kind.tone, large: true, scale: 1.8)
                    if let controller = Verdicts.controller(game.entry) {
                        Label(controller.rawValue, systemImage: "gamecontroller")
                            .font(.system(size: 23, weight: .medium))
                            .padding(.horizontal, 20).padding(.vertical, 11)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                }
                // the facts behind the answer, so the TV says why without opening Why (X shows them all)
                let facts = verdict.extra + verdict.reasons.map { $0.text + ($0.source.map { "  (\($0))" } ?? "") }
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(facts.prefix(3).enumerated()), id: \.offset) { _, fact in Text(fact).lineLimit(1) }
                    }
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if store.runningGame?.id == game.id {
                Text("Running now").font(.system(size: 24, weight: .semibold)).foregroundStyle(.green)
            } else if let played = game.lastPlayed {
                Text("Last played \(played, format: .relative(presentation: .named))")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.85))
            }
            playPrompt(game).padding(.top, 10)
        }
    }

    /// What A does on the selected game, as the screen's one big button.
    private func playPrompt(_ game: LibraryGame) -> some View {
        let label: String
        var waiting = false
        switch Couch.primary(selected: game.id, running: store.runningGame?.id, starting: store.starting?.id) {
        case .resume: label = "Resume"
        case .quitAndPlay: label = "Quit \(store.runningGame?.name ?? "the game") and Play"
        case .play: label = game.isSteamClient ? "Open Steam" : "Play"
        default: label = "Starting \(store.starting?.name ?? game.name)"; waiting = true   // A waits meanwhile
        }
        return HStack(spacing: 14) {
            Group {
                if waiting { ProgressView().controlSize(.small) } else { Text("A").font(.system(size: 24, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(width: 48, height: 48).background(.black.opacity(0.75), in: Circle())
            Text(label).font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
        }
        .padding(.leading, 8).padding(.trailing, 36).padding(.vertical, 8)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .onTapGesture { primary(game) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waiting ? label : "A \(label)")
        .accessibilityAddTraits(.isButton)
    }

    private var rowView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { at, game in
                        let isSelected = at == index
                        VStack(alignment: .leading, spacing: 10) {
                            CoverView(game: game)
                                .frame(width: isSelected ? 230 : 170)
                                .padding(5)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 4))
                                .shadow(color: .black.opacity(isSelected ? 0.6 : 0.3), radius: isSelected ? 20 : 8, y: 8)
                            Text(game.name).font(.system(size: isSelected ? 20 : 17, weight: .semibold)).lineLimit(1)
                                .frame(width: isSelected ? 230 : 170, alignment: .leading)
                                .opacity(isSelected ? 1 : 0.7)
                        }
                        .id(game.id)
                        .animation(.easeOut(duration: 0.18), value: index)
                        .onTapGesture { select(at) }
                    }
                }
                .padding(.horizontal, 72)
            }
            .onChange(of: index) { _, at in
                if games.indices.contains(at) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(games[at].id, anchor: .center) } }
            }
        }
        .frame(height: 420)
    }

    private var hints: some View {
        HStack(spacing: 34) {
            hint("X", "Why"); hint("Y", "Hide"); hint("Menu", "Options")
            Spacer()
            Text("Hold Select + Start in a game to come back here")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func hint(_ button: String, _ word: String?) -> some View {
        HStack(spacing: 10) {
            Text(button).font(.system(size: 17, weight: .bold))
                .padding(.horizontal, button.count > 1 ? 12 : 0).frame(minWidth: 34, minHeight: 34)
                .background(.white.opacity(0.18), in: Capsule())
            if let word { Text(word).font(.system(size: 19, weight: .medium)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word.map { "\(button) \($0)" } ?? button)
    }

    private func overlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(40)
                .frame(maxWidth: 900, alignment: .leading)
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func whyPanel(_ game: LibraryGame) -> some View {
        let verdict = Verdicts.play(game.entry)
        return overlay {
            Text(verdict.headline).font(.system(size: 34, weight: .bold))
            ForEach(verdict.extra, id: \.self) { Text($0).font(.system(size: 22, weight: .semibold)) }
            ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                (Text(reason.text) + Text(reason.source.map { "  " + $0 } ?? "").foregroundColor(.secondary))
                    .font(.system(size: 22))
            }
            if let controller = Verdicts.controller(game.entry) {
                Label(controller.rawValue, systemImage: "gamecontroller").font(.system(size: 22))
            }
            Text("B Close").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private func menuPanel(_ at: Int) -> some View {
        overlay {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 28, weight: i == at ? .bold : .regular))
                    if i == at, let detail = item.detail {
                        Text(detail).font(.system(size: 20)).foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(i == at ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("A Choose  B Close").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private func confirmPanel(_ pending: Confirm) -> some View {
        overlay {
            switch pending {
            case .hide(let game):
                Text("Hide \(game.name)?").font(.system(size: 34, weight: .bold))
                Text("Menu > Show Hidden Games brings it back.").font(.system(size: 22)).foregroundStyle(.secondary)
            case .quitAndPlay(let running, let next):
                Text("Quit \(running.name) and play \(next.name)").font(.system(size: 34, weight: .bold))
            }
            Text("A Confirm  B Cancel").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private func messagePanel(_ message: String) -> some View {
        overlay {
            Text(message).font(.system(size: 26)).fixedSize(horizontal: false, vertical: true)
            Text("B Dismiss").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}
