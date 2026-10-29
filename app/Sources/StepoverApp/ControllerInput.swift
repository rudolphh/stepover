import Foundation
import GameController
import StepoverKit

/// Controller presses for couch mode: each newly pressed button once, and a held direction again at
/// CouchRow.repeats' pace. The keyboard reaches the same handler through CouchView's key presses.
@MainActor
final class ControllerBridge: ObservableObject {
    var onPress: ((CouchButton) -> Void)?
    private var held: Set<CouchButton> = []
    private var heldSince: [CouchButton: Date] = [:]
    private var repeatsSent: [CouchButton: Int] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        held = []
    }

    /// Reads the first controller's buttons (polling keeps one code path for pressing and holding).
    private func poll() {
        guard let pad = GCController.controllers().first?.extendedGamepad else { held = []; return }
        var pressed: Set<CouchButton> = []
        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5 { pressed.insert(.up) }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5 { pressed.insert(.down) }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5 { pressed.insert(.left) }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5 { pressed.insert(.right) }
        if pad.buttonA.isPressed { pressed.insert(.a) }
        if pad.buttonB.isPressed { pressed.insert(.b) }
        if pad.buttonX.isPressed { pressed.insert(.x) }
        if pad.buttonY.isPressed { pressed.insert(.y) }
        if pad.buttonMenu.isPressed { pressed.insert(.menu) }
        if pad.buttonOptions?.isPressed == true { pressed.insert(.select) }
        if pad.buttonHome?.isPressed == true { pressed.insert(.home) }
        let now = Date()
        for button in pressed.subtracting(held) {
            heldSince[button] = now
            repeatsSent[button] = 1
            onPress?(button)
        }
        for button in held.subtracting(pressed) { heldSince[button] = nil; repeatsSent[button] = nil }
        for button in pressed.intersection([.up, .down, .left, .right]) {
            guard let since = heldSince[button] else { continue }
            let due = CouchRow.repeats(heldFor: now.timeIntervalSince(since))
            while (repeatsSent[button] ?? 1) < due {
                repeatsSent[button, default: 1] += 1
                onPress?(button)
            }
        }
        held = pressed
    }
}
