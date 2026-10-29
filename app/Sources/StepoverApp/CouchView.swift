import AppKit
import StepoverKit
import SwiftUI

/// Couch mode: the Library full screen for a TV across the room, driven by a controller (or the keyboard:
/// arrows, Return = A, Escape = B, Space = X, Delete = Y, Tab = Menu). Never a Mac alert while it's up. The look follows
/// the mockup the maintainer approved on 2026-10-29: the game's key art and logo, the answers, Steam's description.
/// Spec: docs/superpowers/specs/2026-10-28-couch-mode-design.md.
struct CouchView: View {
    @EnvironmentObject var store: Store
    @StateObject private var input = ControllerBridge()
    @State private var focus: String?   // the selected game's id: playing a game moves it, and focus goes along
    @State private var place = 0        // where focus was, for when its game is hidden
    @State private var showDetails = false
    @State private var menu: Int?
    @State private var confirm: Confirm?
    @State private var enteredFullScreen = false
    @State private var screen: NSScreen?   // the screen couch mode is on
    @State private var adding: [AddChoice]?   // Menu > Add a Game: the games waiting in Downloads
    @State private var addAt = 0
    @FocusState private var focused: Bool

    enum Confirm: Equatable {
        case hide(LibraryGame)
        case quitAndPlay(running: LibraryGame, next: LibraryGame)
        case trash(bottle: String, text: String)   // after a game from a dropped folder had a good run (D13)
    }

    /// A game waiting in Downloads, as Menu > Add a Game lists it.
    struct AddChoice: Identifiable {
        let url: URL
        let name: String
        let verdict: String
        let there: Bool
        var id: String { url.path }
    }

    private let macDelete = KeyEquivalent("\u{7F}")

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
        if !store.running.isEmpty {   // as the Dock's: every running bottle, Steam included
            items.append(("Stop Everything", nil, { store.bottles.filter(\.isRunning).forEach(store.stop) }))
        }
        if !store.runtimeReady && store.runtimeFailed { items.append(("Retry Download", nil, { store.installRuntime() })) }
        items.append((store.openAtLogin ? "Open at Login: On" : "Open at Login: Off",
                      "Opens Stepover when you log in to this Mac, so couch mode is ready without the mouse.",
                      { store.setOpenAtLogin(!store.openAtLogin) }))
        items.append(("Add a Game", "Games waiting in your Downloads folder, from their installer or folder.", { openAddList() }))
        return items
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(geo.size)
                VStack(alignment: .leading, spacing: 0) {
                    statusLine.padding(.horizontal, 96).padding(.top, 40)
                    Spacer(minLength: 16)
                    if let game = selected { hero(game).padding(.horizontal, 96) }
                    Spacer(minLength: 20)
                    rowView
                    hints.padding(.horizontal, 96).padding(.top, 18).padding(.bottom, 34)
                }
                if showDetails, let game = selected { detailsPanel(game) }
                if let menu { menuPanel(menu) }
                if let adding { addPanel(adding) }
                if let confirm { confirmPanel(confirm) }
                if let message = store.alert { messagePanel(message) }
            }
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // a Mac's Delete key types U+007F, not SwiftUI's .delete (U+0008)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space, .delete, macDelete, .tab]) { press in
            let map: [KeyEquivalent: CouchButton] = [.leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
                                                     .return: .a, .escape: .b, .space: .x, .delete: .y, macDelete: .y, .tab: .menu]
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
        .onChange(of: store.justAdded) { _, id in if let id { focus = id } }   // the game that just finished installing
        .onChange(of: store.endedGame) { _, ended in
            if let ended { focus = ended.id }
            if let ended, let text = store.trashOffers[ended.bottle.name] { confirm = .trash(bottle: ended.bottle.name, text: text) }
        }
    }

    // MARK: input

    private func handle(_ button: CouchButton) {
        if store.alert != nil { if button == .b || button == .a { store.alert = nil }; return }
        if let pending = confirm {
            if button == .a { perform(pending) }
            if button == .b, case .trash(let bottle, _) = pending { store.keepSource(bottle: bottle) }
            if button == .a || button == .b { confirm = nil }
            return
        }
        if let choices = adding {
            switch button {
            case .up: addAt = max(addAt - 1, 0)
            case .down: addAt = min(addAt + 1, choices.count - 1)
            case .a: if choices.indices.contains(addAt) { store.add([choices[addAt].url]) }; adding = nil
            case .b, .menu: adding = nil
            default: break
            }
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
        if showDetails { if button == .b || button == .x { showDetails = false }; return }
        var row = CouchRow(count: games.count, index: index)
        switch button {
        case .left: row.move(-1); select(row.index)
        case .right: row.move(1); select(row.index)
        case .a: if let game = selected { primary(game) }
        case .b: if let job = selected?.install { installAction(job, .b) }
        case .x: showDetails = selected != nil
        case .y:
            guard let game = selected else { break }
            if Couch.secondary(hidden: store.hidden.contains(game.id)) == .unhide { store.setHidden(game, false) } else { confirm = .hide(game) }
        case .menu: menu = 0
        default: break
        }
    }

    /// A and B on a game on its way in (D12): Try Again or Remove a failure, Install Anyway, Play the copy already there.
    private func installAction(_ job: InstallJob, _ button: CouchButton) {
        switch Couch.installAction(job.stage, button: button) {
        case .tryAgain: store.tryAgain(job)
        case .removeInstall: store.removeInstall(job)
        case .installAnyway: store.installAnyway(job)
        case .playExisting(let id): focus = id; store.playExisting(id)
        default: break
        }
    }

    /// Menu > Add a Game: the games in Downloads, read off the main thread (looking at installers takes a moment).
    private func openAddList() {
        guard store.downloadsAllowed else { store.alert = "Allow Stepover to see your Downloads on the Mac first"; return }
        let index = store.gameIndex, library = store.library
        Task.detached {
            let choices = DownloadsScan.candidates(in: Paths.downloads).map { url -> AddChoice in
                let name = FolderName.clean(url.lastPathComponent)
                let entry = index.match(name: name, exe: nil)
                return AddChoice(url: url, name: entry?.name ?? name, verdict: Verdicts.play(entry).kind.short,
                                 there: Recognize.existing(Recognized(name: entry?.name ?? name, entry: entry), in: library) != nil)
            }
            await MainActor.run {
                if choices.isEmpty { store.alert = "No games in your Downloads folder yet." } else { addAt = 0; adding = choices }
            }
        }
    }

    private func primary(_ game: LibraryGame) {
        if let job = game.install { installAction(job, .a); return }
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
        case .trash(let bottle, _): store.moveSourceToTrash(bottle: bottle)
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

    /// The game's key art across the top right, its color behind everything, fading to it toward the text and the
    /// row. A game without key art keeps the blurred cover. Overlays never size the base (a filling image as a
    /// ZStack layer once made the screen taller than the display).
    private func backdrop(_ size: CGSize) -> some View {
        let id = selected?.steamAppID
        let base = id.flatMap { store.tint[$0] }?.blended(withFraction: 0.82, of: .black) ?? NSColor(white: 0.08, alpha: 1)
        let ground = Color(nsColor: base)
        return ground
            .overlay(alignment: .topTrailing) {
                if let id, let art = store.keyArt[id] {
                    let height = size.height * 0.7
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: max(height * art.size.width / max(art.size.height, 1), size.width), height: height,
                               alignment: .trailing)
                        .id(id).transition(.opacity)
                } else if let id, let cover = store.art[id] {
                    Image(nsImage: cover).resizable().scaledToFill().blur(radius: 70).opacity(0.55)
                        .frame(width: size.width, height: size.height).id(id).transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: ground, location: 0), .init(color: ground.opacity(0.9), location: 0.45),
                                       .init(color: ground.opacity(0), location: 0.7)], startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(stops: [.init(color: ground.opacity(0), location: 0.38), .init(color: ground.opacity(0.8), location: 0.6),
                                       .init(color: ground, location: 0.72)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
            }
            .animation(.easeInOut(duration: 0.4), value: id)
            .ignoresSafeArea()
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 32) {
            if !store.runtimeReady, let progress = store.runtimeProgress {
                Text("Getting ready to play: \(Int(progress * 100))%")
            } else if !store.runtimeReady, store.runtimeFailed {
                Text("Couldn't get what games need. Menu > Retry Download")
            } else if let screen, !isMain(screen) {
                Text("Games open on your other screen. Menu > Make This the Main Display")
            }
            Spacer()
            Label(store.controllerName ?? "No controller", systemImage: "gamecontroller")
                .accessibilityLabel(store.controllerName.map { "\($0) connected" } ?? "No controller")
            TimelineView(.everyMinute) { context in Text(context.date, format: .dateTime.hour().minute()) }
        }
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
    }

    /// The game's logo as its title, or its name when it has none or a dark one.
    @ViewBuilder private func title(_ game: LibraryGame) -> some View {
        if let id = game.steamAppID, let logo = store.logo[id] {
            Image(nsImage: logo).resizable().scaledToFit()
                .frame(maxWidth: 600, maxHeight: 200, alignment: .bottomLeading)
                .frame(height: 200, alignment: .bottomLeading)
                .accessibilityLabel(game.name)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(game.name)
                .font(.system(size: 72, weight: .bold).width(.expanded))
                .lineLimit(2).minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The selected game: its title, the answer to "will it play here" (the Library's words, the answer in bold),
    /// the controller answer and any fix in smaller type, Steam's description, and Play.
    private func hero(_ game: LibraryGame) -> some View {
        let verdict = Verdicts.play(game.entry)
        let (answer, qualifier) = Verdicts.parts(verdict.headline)
        let blurb = game.steamAppID.flatMap { store.about[$0]?.blurb }
        return VStack(alignment: .leading, spacing: 22) {
            title(game)
            if game.isSteamClient {
                Text("Your Steam games show up here by themselves.").font(.system(size: 27)).foregroundStyle(.white.opacity(0.86))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Circle().fill(verdict.kind.tone.color(.dark)).frame(width: 14, height: 14).accessibilityHidden(true)
                        Text(answer).fontWeight(.bold)
                        if let qualifier { Text(qualifier).foregroundStyle(.white.opacity(0.8)) }
                    }
                    .font(.system(size: 31))
                    .accessibilityElement(children: .combine)
                    Group {
                        if let controller = Verdicts.controller(game.entry) { Label(controller.rawValue, systemImage: "gamecontroller") }
                        ForEach(verdict.extra, id: \.self) { line in
                            Label(line, systemImage: line == Verdicts.fixLine ? "wrench.and.screwdriver" : "info.circle")
                        }
                    }
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.86))
                }
            }
            if let blurb {
                Text(blurb).font(.system(size: 27)).lineSpacing(6).lineLimit(2)
                    .frame(maxWidth: 860, alignment: .leading)
                    .foregroundStyle(.white.opacity(0.86))
            }
            if let job = game.install {
                Text(job.stage.text).font(.system(size: 27, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if store.hidden.contains(game.id) {
                Label("Hidden. Y puts it back with your games.", systemImage: "eye.slash")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.86))
            }
            HStack(spacing: 32) {
                if let job = game.install { installPrompt(job) } else { playPrompt(game) }
                if store.runningGame?.id == game.id {
                    Text("Running now").font(.system(size: 24, weight: .semibold)).foregroundStyle(.green)
                } else if let played = game.lastPlayed {
                    Text("Last played \(played, format: .relative(presentation: .named))")
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 940, alignment: .leading)
    }

    /// What A does on a game on its way in, and B to remove a failed one; nothing to press while it installs.
    @ViewBuilder private func installPrompt(_ job: InstallJob) -> some View {
        let label: String? = {
            switch Couch.installAction(job.stage, button: .a) {
            case .tryAgain: return "Try Again"
            case .installAnyway: return "Install Anyway"
            case .playExisting: return "Play"
            default: return nil
            }
        }()
        if let label {
            HStack(spacing: 16) {
                Text("A").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(Color(white: 0.07), in: Circle())
                Text(label).font(.system(size: 32, weight: .bold)).foregroundStyle(Color(white: 0.07))
            }
            .padding(.leading, 10).padding(.trailing, 40).frame(height: 76)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .onTapGesture { installAction(job, .a) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A \(label)")
            .accessibilityAddTraits(.isButton)
            if Couch.installAction(job.stage, button: .b) == .removeInstall { hint("B", "Remove") }
        } else if job.stage.isActive {
            ProgressView().controlSize(.large).accessibilityLabel(job.stage.text)
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
        return HStack(spacing: 16) {
            Group {
                if waiting { ProgressView().controlSize(.regular) } else { Text("A").font(.system(size: 26, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56).background(Color(white: 0.07), in: Circle())
            Text(label).font(.system(size: 32, weight: .bold)).foregroundStyle(Color(white: 0.07))
        }
        .padding(.leading, 10).padding(.trailing, 40).frame(height: 76)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
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
                        CoverView(game: game)
                            .frame(width: isSelected ? 180 : 144)
                            .padding(5)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 4))
                            .shadow(color: .black.opacity(isSelected ? 0.55 : 0.4), radius: isSelected ? 20 : 10, y: 8)
                            .opacity(isSelected ? 1 : 0.7)
                            .id(game.id)
                            .animation(.easeOut(duration: 0.18), value: index)
                            .onTapGesture { select(at) }
                            .accessibilityLabel(game.name)
                    }
                }
                .padding(.horizontal, 96)
                .padding(.vertical, 12)
            }
            .onChange(of: index) { _, at in
                if games.indices.contains(at) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(games[at].id, anchor: .center) } }
            }
        }
        .frame(height: 320)
    }

    private var hints: some View {
        HStack(spacing: 36) {
            hint("X", "Details")
            hint("Y", selected.map { store.hidden.contains($0.id) } == true ? "Show in Library" : "Hide")
            hint("Menu", "Options")
            Spacer()
            Text("In a game, hold Select + Start for a second to come back here")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.82))
        }
    }

    private func hint(_ button: String, _ word: String?) -> some View {
        HStack(spacing: 12) {
            Text(button).font(.system(size: button.count > 1 ? 18 : 19, weight: .bold))
                .padding(.horizontal, button.count > 1 ? 14 : 0).frame(minWidth: 36, minHeight: 36)
                .background(.white.opacity(0.18), in: Capsule())
            if let word { Text(word).font(.system(size: 22, weight: .medium)) }
        }
        .foregroundStyle(.white.opacity(0.88))
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

    /// X: everything behind the answers, with sources, beside the game rather than over it.
    private func detailsPanel(_ game: LibraryGame) -> some View {
        let verdict = Verdicts.play(game.entry)
        let (answer, qualifier) = Verdicts.parts(verdict.headline)
        let about = game.steamAppID.flatMap { store.about[$0] }
        let genres = (about?.genres.prefix(2)).map { $0.joined(separator: ", ") } ?? ""
        let meta = [genres.isEmpty ? nil : genres + ".", about?.year.map { "Released \($0)." }].compactMap { $0 }.joined(separator: " ")
        return ZStack(alignment: .trailing) {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 30) {
                Text(game.name).font(.system(size: 44, weight: .bold)).accessibilityAddTraits(.isHeader)
                if !meta.isEmpty { Text(meta).font(.system(size: 24)).foregroundStyle(.white.opacity(0.8)) }
                if !game.isSteamClient {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Will it play on this Mac").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        HStack(spacing: 14) {
                            Circle().fill(verdict.kind.tone.color(.dark)).frame(width: 14, height: 14).accessibilityHidden(true)
                            Text(answer).fontWeight(.bold)
                            if let qualifier { Text(qualifier).foregroundStyle(.white.opacity(0.8)) }
                        }
                        .font(.system(size: 30))
                        ForEach(verdict.extra, id: \.self) { Text($0).font(.system(size: 24)) }
                        ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                            (Text(reason.text) + Text(reason.source.map { "  " + $0 } ?? "").foregroundColor(.white.opacity(0.66)))
                                .font(.system(size: 24)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let controller = Verdicts.controller(game.entry) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Controller").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                            Text(controller.rawValue).font(.system(size: 28))
                        }
                    }
                }
                Spacer()
                hint("B", "Close")
            }
            .padding(.horizontal, 72).padding(.top, 96).padding(.bottom, 72)
            .frame(width: 780, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.07).opacity(0.97), ignoresSafeAreaEdges: .all)
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
                Text("To bring it back: Menu > Show Hidden Games, then Y on it.").font(.system(size: 22)).foregroundStyle(.secondary)
            case .quitAndPlay(let running, let next):
                Text("Quit \(running.name) and play \(next.name)").font(.system(size: 34, weight: .bold))
            case .trash(_, let text):
                Text(text).font(.system(size: 34, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            }
            if case .trash = pending {
                Text("A Move to Trash  B Keep").font(.system(size: 18)).foregroundStyle(.secondary)
            } else {
                Text("A Confirm  B Cancel").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
    }

    /// Menu > Add a Game: what's in Downloads, with the answer and whether it's already in the Library.
    private func addPanel(_ choices: [AddChoice]) -> some View {
        overlay {
            Text("Add a Game").font(.system(size: 34, weight: .bold)).accessibilityAddTraits(.isHeader)
            ForEach(Array(choices.enumerated()), id: \.element.id) { i, choice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.name).font(.system(size: 28, weight: i == addAt ? .bold : .regular))
                    Text(choice.there ? "\(choice.verdict). Already in your Library" : choice.verdict)
                        .font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(i == addAt ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("A Add  B Close").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private func messagePanel(_ message: String) -> some View {
        overlay {
            Text(message).font(.system(size: 26)).fixedSize(horizontal: false, vertical: true)
            Text("B Dismiss").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}
