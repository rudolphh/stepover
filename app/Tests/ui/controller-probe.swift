// Couch mode spike (plan B3, Task 1). A tiny menu-bar-less app that listens to the game controller while
// another app (a full-screen game) is in front, logs every button change with whether it was the active app,
// and on Select+Start held 1 s (or Home held 0.5 s) shows a non-activating floating panel over everything.
// Log: ~/Library/Logs/Stepover/controller-probe.log. Built and opened by controller-probe.sh.
import AppKit
import GameController

final class Probe: NSObject, NSApplicationDelegate {
    private var held: Set<String> = []
    private var since: [String: Date] = [:]
    private var fired: Set<String> = []
    private var panel: NSPanel?
    private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Stepover/controller-probe.log")
    private var pad: GCExtendedGamepad?

    func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        print(text, terminator: "")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close() }
        else { try? Data(text.utf8).write(to: logURL) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GCController.shouldMonitorBackgroundEvents = true
        let screens = NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))\($0 == NSScreen.screens.first ? " (main)" : "")" }
        write("probe started; screens: \(screens.joined(separator: ", ")); shouldMonitorBackgroundEvents=\(GCController.shouldMonitorBackgroundEvents)")
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.write("controller disconnected")
        }
        GCController.controllers().forEach(attach)
        if GCController.controllers().isEmpty { write("no controller yet; connect one") }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    func attach(_ controller: GCController) {
        write("connected: \(controller.vendorName ?? "unnamed") (\(controller.productCategory)); extended gamepad: \(controller.extendedGamepad != nil)")
        pad = controller.extendedGamepad
    }

    func tick() {
        guard let pad else { return }
        let buttons: [(String, GCControllerButtonInput?)] = [
            ("A", pad.buttonA), ("B", pad.buttonB), ("X", pad.buttonX), ("Y", pad.buttonY),
            ("Home", pad.buttonHome), ("Select", pad.buttonOptions), ("Start", pad.buttonMenu),
            ("L1", pad.leftShoulder), ("R1", pad.rightShoulder), ("Up", pad.dpad.up), ("Down", pad.dpad.down),
            ("Left", pad.dpad.left), ("Right", pad.dpad.right)]
        let pressed = Set(buttons.filter { $0.1?.isPressed == true }.map(\.0))
        let now = Date()
        if pressed != held {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            write("pressed: [\(pressed.sorted().joined(separator: ", "))] probe active: \(NSApp.isActive), front app: \(front)")
            for name in pressed.subtracting(held) { since[name] = now }
            for name in held.subtracting(pressed) { since[name] = nil; fired.remove(name) }
            if !(pressed.contains("Select") && pressed.contains("Start")) { fired.remove("chord") }
            held = pressed
        }
        if pressed.contains("Select"), pressed.contains("Start"), !fired.contains("chord"),
           let a = since["Select"], let b = since["Start"], now.timeIntervalSince(max(a, b)) >= 1.0 {
            fired.insert("chord"); show("Select + Start held: Stepover would show Resume / Quit Game here")
        }
        if pressed.contains("Home"), !fired.contains("Home"), let t = since["Home"], now.timeIntervalSince(t) >= 0.5 {
            fired.insert("Home"); show("Home held: Stepover would show Resume / Quit Game here")
        }
    }

    func show(_ message: String) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 760, height: 150)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        let label = NSTextField(labelWithString: "Probe: " + message)
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 50, width: size.width - 40, height: 50)
        panel.contentView?.addSubview(label)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
        write("PANEL SHOWN on \(screen.localizedName): \(message); front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"); panel visible: \(panel.isVisible)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.panel?.orderOut(nil); self?.panel = nil }
    }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.accessory)
app.run()
