import AppKit
import GameController
import StepoverKit

/// Controller presses for couch mode, through PressTracker: each newly pressed button once, a held direction
/// again at CouchRow.repeats' pace, and nothing while Stepover isn't in front (the in-game panel listens in the
/// background, so a game's presses would otherwise reach the couch screen). The keyboard reaches the same
/// handler through CouchView's key presses.
@MainActor
final class ControllerBridge: ObservableObject {
    var onPress: ((CouchButton) -> Void)?
    private var tracker = PressTracker()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tracker = PressTracker()
    }

    /// Reads the first controller's buttons (polling keeps one code path for pressing and holding).
    private func poll() {
        let pressed = GCController.couchPad?.couchButtons ?? []
        for button in tracker.update(pressed, at: Date().timeIntervalSinceReferenceDate, active: NSApp.isActive) {
            onPress?(button)
        }
    }
}

extension GCController {
    /// The controller couch mode and the in-game panel read. None when STEPOVER_NO_CONTROLLER is set: the scripted
    /// checks drive their test copies with the keyboard, and a controller in someone's hands must not press A there.
    static var couchPad: GCExtendedGamepad? {
        ProcessInfo.processInfo.environment["STEPOVER_NO_CONTROLLER"] == nil ? controllers().first?.extendedGamepad : nil
    }
}

extension GCExtendedGamepad {
    /// The buttons held right now, in couch mode's terms (Start is Menu, the left stick moves too).
    var couchButtons: Set<CouchButton> {
        var pressed: Set<CouchButton> = []
        if dpad.up.isPressed || leftThumbstick.yAxis.value > 0.5 { pressed.insert(.up) }
        if dpad.down.isPressed || leftThumbstick.yAxis.value < -0.5 { pressed.insert(.down) }
        if dpad.left.isPressed || leftThumbstick.xAxis.value < -0.5 { pressed.insert(.left) }
        if dpad.right.isPressed || leftThumbstick.xAxis.value > 0.5 { pressed.insert(.right) }
        if buttonA.isPressed { pressed.insert(.a) }
        if buttonB.isPressed { pressed.insert(.b) }
        if buttonX.isPressed { pressed.insert(.x) }
        if buttonY.isPressed { pressed.insert(.y) }
        if buttonMenu.isPressed { pressed.insert(.menu) }
        if buttonOptions?.isPressed == true { pressed.insert(.select) }
        if buttonHome?.isPressed == true { pressed.insert(.home) }
        return pressed
    }
}
