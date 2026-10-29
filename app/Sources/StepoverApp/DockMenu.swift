import AppKit
import StepoverKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store? {
        didSet { if let store, !pendingOpen.isEmpty { store.add(pendingOpen); pendingOpen = [] } }
    }
    /// Items dropped on the Dock icon before the window (and its store) was up.
    private var pendingOpen: [URL] = []

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        store.map(DockMenu.make)
    }

    /// A game's installer or folder dropped on Stepover's Dock icon (spec D1).
    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.add(urls) } else { pendingOpen += urls }
    }

    /// Quitting while a game installs asks first; the install then stops and reads Interrupted (spec D10).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, let id = store.installingJob, let job = store.installs.first(where: { $0.id == id }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A game is installing"
        alert.informativeText = "Quit anyway? Installing \(job.name) stops, and Try Again starts it over."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        store.stopInstallForQuit()
        return .terminateNow
    }
}

/// The menu on Stepover's Dock icon: recent games, every game by bottle, Run .exe… and Stop Everything.
/// A running game is checked and offers Bring to Front and Stop instead of starting a second copy.
@MainActor
enum DockMenu {
    struct Game {
        let bottle: Bottle
        let program: Program
        let pids: [Int32]   // empty when it isn't running
        let bottleHasOthers: Bool
    }

    static let recentLimit = 5

    static func make(_ store: Store) -> NSMenu {
        let menu = NSMenu()
        let processes = RunningPrograms.processes()
        var byBottle: [(Bottle, [Game])] = []
        for bottle in store.bottles {
            let programs = store.config(bottle).programs
            guard !programs.isEmpty else { continue }
            let games = RunningPrograms.inBottle(processes, bottlePath: bottle.url.path).filter { !$0.isSystem }
            byBottle.append((bottle, programs.map { program in
                // A launcher often exits once the game starts, so a bottle holding one program counts
                // any running game process as that program.
                var pids = games.filter { $0.exeName == program.exeName.lowercased() }.map(\.pid)
                if pids.isEmpty && programs.count == 1 { pids = games.map(\.pid) }
                return Game(bottle: bottle, program: program, pids: pids, bottleHasOthers: programs.count > 1)
            }))
        }
        let all = byBottle.flatMap(\.1)
        guard !all.isEmpty else {
            menu.addItem(disabled("No games yet"))
            return menu
        }

        let recent = RecentGames.load().compactMap { entry in
            all.first { $0.bottle.name == entry.bottle && $0.program.name == entry.program }
        }.prefix(recentLimit)
        for game in recent { menu.addItem(item(game, store)) }
        if !recent.isEmpty { menu.addItem(.separator()) }

        let allItem = NSMenuItem(title: "All Games", action: nil, keyEquivalent: "")
        let allMenu = NSMenu()
        for (bottle, games) in byBottle {
            if byBottle.count > 1 { allMenu.addItem(.sectionHeader(title: bottle.name)) }
            for game in games { allMenu.addItem(item(game, store)) }
        }
        allItem.submenu = allMenu
        menu.addItem(allItem)

        let runItem = NSMenuItem(title: "Run .exe…", action: nil, keyEquivalent: "")
        let runMenu = NSMenu()
        for bottle in store.bottles {
            runMenu.addItem(ActionItem("In \(bottle.name)…") {
                NSApp.activate()
                store.runExe(in: bottle)
            })
        }
        runItem.submenu = runMenu
        menu.addItem(.separator())
        menu.addItem(runItem)

        let running = store.bottles.filter(\.isRunning)
        if !running.isEmpty {
            menu.addItem(ActionItem("Stop Everything") { running.forEach(store.stop) })
        }
        return menu
    }

    static func item(_ game: Game, _ store: Store) -> NSMenuItem {
        let item: NSMenuItem
        if game.pids.isEmpty {
            item = ActionItem(game.program.name) { store.play(game.program, in: game.bottle) }
        } else {
            item = NSMenuItem(title: game.program.name, action: nil, keyEquivalent: "")
            item.state = .on
            let sub = NSMenu()
            sub.addItem(ActionItem("Bring to Front") { bringToFront(game.pids) })
            sub.addItem(ActionItem(game.bottleHasOthers ? "Stop Everything in \(game.bottle.name)" : "Stop") {
                store.stop(game.bottle)
            })
            item.submenu = sub
        }
        if let icon = store.icon(for: game.program, in: game.bottle)?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    /// Wine registers each Windows program as a regular macOS app (named "wine").
    static func bringToFront(_ pids: [Int32]) {
        guard let app = pids.lazy.compactMap({ NSRunningApplication(processIdentifier: $0) })
            .first(where: { $0.activationPolicy == .regular }) else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])
    }

    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
