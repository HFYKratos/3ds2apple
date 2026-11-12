//
//  GameControllerInput.swift
//  3ds2apple
//
//  I3-T1: MFi / Xbox / DualSense controllers → InputState.
//
//  Every change recomputes the whole controller mask from each button's
//  `isPressed` state, so there is no per-bit bookkeeping that can get out of
//  sync when controllers connect, disconnect or repeat events.
//

import Foundation
import GameController

/// Bridges hardware controllers into the shared `InputState`.
final class GameControllerManager {
    private let input: InputState
    private let onConnectionChange: (String?) -> Void
    private var observers: [NSObjectProtocol] = []
    private var running = false

    init(input: InputState, onConnectionChange: @escaping (String?) -> Void) {
        self.input = input
        self.onConnectionChange = onConnectionChange
    }

    /// Observes connections and attaches paddles that are already connected.
    /// Main thread.
    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let controller = note.object as? GCController {
                self.attach(controller)
            }
            self.refresh()
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        GCController.controllers().forEach(attach)
        refresh()
        AppLog.log("[3ds2apple] controller support started")
    }

    /// Main thread.
    func stop() {
        guard running else { return }
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        input.clearController()
    }

    // MARK: - Wiring

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let handler: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, _ in
            self?.refresh()
        }
        let buttons = [
            gamepad.buttonA,
            gamepad.buttonB,
            gamepad.buttonX,
            gamepad.buttonY,
            gamepad.leftShoulder,
            gamepad.rightShoulder,
            gamepad.leftTrigger,
            gamepad.rightTrigger,
            gamepad.buttonMenu,
            gamepad.dpad.up,
            gamepad.dpad.down,
            gamepad.dpad.left,
            gamepad.dpad.right
        ]
        for button in buttons {
            button.valueChangedHandler = handler
        }
        if let options = gamepad.buttonOptions {
            options.valueChangedHandler = handler
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, _, _ in
            self?.refresh()
        }
    }

    /// Recomputes buttons + circle pad from the currently connected pads.
    /// Runs on the main thread (notification queue and input handlers).
    private func refresh() {
        var mask: UInt32 = 0
        var stickX: Float = 0
        var stickY: Float = 0
        var controllerName: String?

        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            mask |= Self.buttonMask(from: gamepad)
            if controllerName == nil {
                controllerName = controller.vendorName
            }
            if stickX == 0 && stickY == 0 {
                // 3DS Circle Pad is analog: controller left stick, +y is up in
                // GameController, which matches the 3DS convention.
                stickX = gamepad.leftThumbstick.xAxis.value
                stickY = gamepad.leftThumbstick.yAxis.value
            }
        }

        input.setControllerButtons(mask)
        input.setControllerStick(x: stickX, y: stickY)
        onConnectionChange(controllerName)
    }

    private static func buttonMask(from gamepad: GCExtendedGamepad) -> UInt32 {
        var mask: UInt32 = 0
        if gamepad.buttonA.isPressed { mask |= ZKButton.a }
        if gamepad.buttonB.isPressed { mask |= ZKButton.b }
        if gamepad.buttonX.isPressed { mask |= ZKButton.x }
        if gamepad.buttonY.isPressed { mask |= ZKButton.y }
        if gamepad.dpad.up.isPressed { mask |= ZKButton.up }
        if gamepad.dpad.down.isPressed { mask |= ZKButton.down }
        if gamepad.dpad.left.isPressed { mask |= ZKButton.left }
        if gamepad.dpad.right.isPressed { mask |= ZKButton.right }
        if gamepad.leftShoulder.isPressed { mask |= ZKButton.l }
        if gamepad.rightShoulder.isPressed { mask |= ZKButton.r }
        if gamepad.leftTrigger.isPressed { mask |= ZKButton.zl }
        if gamepad.rightTrigger.isPressed { mask |= ZKButton.zr }
        if gamepad.buttonMenu.isPressed { mask |= ZKButton.start }
        if gamepad.buttonOptions?.isPressed == true { mask |= ZKButton.select }
        return mask
    }
}
