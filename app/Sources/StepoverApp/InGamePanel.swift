import AppKit
import GameController
import StepoverKit
import SwiftUI

/// The in-game panel (spec C5): while a game Stepover started runs, Stepover listens to the controller in the
/// background, and holding Select + Start for a second (or Home, when macOS isn't using it) shows Resume and
/// Quit Game over the game. The panel never takes focus, so the game stays in front with the controller.
@MainActor
final class InGamePanel {
    private unowned let store: Store
    private var game: LibraryGame?
    private var detector = ShortcutDetector()
    private var tracker = PressTracker()
    private var menu = InGameMenu()
    private var timer: Timer?
    private var panel: NSPanel?

    init(store: Store) { self.store = store }

    /// Background listening on while `game` runs, off otherwise; the panel goes away with the game.
    func watch(_ game: LibraryGame?) {
        self.game = game
        if game == nil {
            close()
            timer?.invalidate()
            timer = nil
            GCController.shouldMonitorBackgroundEvents = false
        } else if timer == nil {
            GCController.shouldMonitorBackgroundEvents = true
            detector = ShortcutDetector()
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func poll() {
        let pressed = GCController.couchPad?.couchButtons ?? []
        let now = Date().timeIntervalSinceReferenceDate
        let shortcut = detector.update(pressed, at: now)
        guard panel != nil else {
            // only the shortcut counts, and only while the game is in front (couch mode has its own Menu)
            if shortcut, !NSApp.isActive { show() }
            _ = tracker.update(pressed, at: now, active: false)   // the shortcut's buttons are still held
            return
        }
        for button in tracker.update(pressed, at: now, active: true) { press(button) }
    }

    private func press(_ button: CouchButton) {
        switch menu.press(button) {
        case .none: layout()
        case .resume: close()
        case .quit:
            close()
            guard let game else { return }
            store.quitGame(game) { [store] in store.comeBack(after: game) }
        }
    }

    private func show() {
        guard let game else { return }
        menu = InGameMenu()
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: view(game))
        self.panel = panel
        layout()
        panel.orderFrontRegardless()
    }

    /// Sized for the game's screen (games go full screen on the main display, C2b) and centered on it.
    private func layout() {
        guard let panel, let game, let hosting = panel.contentView as? NSHostingView<InGamePanelView> else { return }
        hosting.rootView = view(game)
        let size = hosting.fittingSize
        let frame = (NSScreen.screens.first ?? NSScreen.main)?.frame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private func view(_ game: LibraryGame) -> InGamePanelView {
        let width = min(max((NSScreen.screens.first?.frame.width ?? 1440) * 0.42, 640), 1100)
        return InGamePanelView(name: game.name, confirming: menu.confirming, width: width) { [weak self] in self?.press($0) }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// What the in-game panel shows: the game, then Resume and Quit Game, or the question before quitting. The
/// hints are buttons too, so the mouse works when a controller isn't handy.
struct InGamePanelView: View {
    let name: String
    let confirming: Bool
    let width: CGFloat
    let act: (CouchButton) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if confirming {
                Text("Quit \(name)?").font(.system(size: 44, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text("Anything you haven't saved in the game is lost.").font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 34) { hint("A", "Quit", .a); hint("B", "Back", .b) }
            } else {
                Text(name).font(.system(size: 44, weight: .bold)).lineLimit(2).accessibilityAddTraits(.isHeader)
                HStack(spacing: 34) { hint("A", "Resume", .a); hint("X", "Quit Game", .x) }
            }
        }
        .foregroundStyle(.white)
        .padding(48)
        .frame(width: width, alignment: .leading)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func hint(_ button: String, _ word: String, _ press: CouchButton) -> some View {
        Button { act(press) } label: {
            HStack(spacing: 12) {
                Text(button).font(.system(size: 22, weight: .bold))
                    .frame(minWidth: 42, minHeight: 42)
                    .background(.white.opacity(0.18), in: Capsule())
                Text(word).font(.system(size: 26, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(button) \(word)")
    }
}
