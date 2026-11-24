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
//  0.2.0 C adds a radial stick dead zone and physical-button → 3DS-button
//  remapping. 0.2.0 final adds physical hotkey combinations: a 2–4 button
//  combination triggers a GameView action once and its buttons are suppressed
//  from the guest while the combination is held.
//

import Foundation
import GameController

/// Bridges hardware controllers into the shared `InputState`.
final class GameControllerManager {
    private let input: InputState
    private let onConnectionChange: (String?) -> Void
    /// Called once per hotkey press cycle on the main thread.
    private let onHotkey: ((HotkeyAction) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    /// Radial dead zone applied to both thumbsticks (0...0.35).
    private var deadzone: Float = 0.14
    /// Physical button raw value -> GamepadAction raw value.
    private var buttonMap: [String: String] = AppSettings.defaultControllerButtonMap
    /// Hotkey action raw value -> physical button raw values, parsed on refresh.
    private var hotkeyMap: [String: [String]] = [:]
    /// Buttons of the hotkey currently being held (suppressed from the guest).
    private var activeHotkeyButtons: Set<String> = []
    /// UI hotkey recorder: receives the currently pressed physical buttons.
    private var recordingHandler: (([PhysicalControllerButton]) -> Void)?

    init(input: InputState,
         onHotkey: ((HotkeyAction) -> Void)? = nil,
         onConnectionChange: @escaping (String?) -> Void) {
        self.input = input
        self.onHotkey = onHotkey
        self.onConnectionChange = onConnectionChange
    }

    /// Updates the radial stick dead zone (main thread).
    func setDeadzone(_ value: Double) {
        deadzone = Float(min(max(value, 0), 0.35))
        refresh()
    }

    /// Replaces the physical button mapping (main thread).
    func setButtonMap(_ map: [String: String]) {
        buttonMap = map
        refresh()
    }

    /// Replaces the hotkey combinations (main thread).
    func setHotkeyMap(_ map: [String: [String]]) {
        hotkeyMap = map
        activeHotkeyButtons = []
        refresh()
    }

    /// Starts/stops the UI recorder; while recording, controller input is
    /// suppressed and no hotkey fires, and the pressed buttons are published.
    func beginRecording(_ handler: @escaping ([PhysicalControllerButton]) -> Void) {
        recordingHandler = handler
        activeHotkeyButtons = []
        refresh()
    }

    func endRecording() {
        recordingHandler = nil
        refresh()
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
        recordingHandler = nil
        activeHotkeyButtons = []
        input.clearController()
    }

    // MARK: - Wiring

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let handler: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, _ in
            self?.refresh()
        }
        for button in Self.allInputs(of: gamepad) {
            button.valueChangedHandler = handler
        }
        if let options = gamepad.buttonOptions {
            options.valueChangedHandler = handler
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, _, _ in
            self?.refresh()
        }
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, _, _ in
            self?.refresh()
        }
    }

    /// Recomputes buttons + circle pad from the currently connected pads.
    /// Runs on the main thread (notification queue and input handlers).
    private func refresh() {
        var mask: UInt32 = 0
        var stickX: Float = 0
        var stickY: Float = 0
        var cStickX: Float = 0
        var cStickY: Float = 0
        var controllerName: String?
        var pressed: Set<PhysicalControllerButton> = []

        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            pressed.formUnion(pressedButtons(on: gamepad))
            if controllerName == nil {
                controllerName = controller.vendorName
            }
            if stickX == 0 && stickY == 0 {
                (stickX, stickY) = Self.applyDeadzone(
                    x: gamepad.leftThumbstick.xAxis.value,
                    y: gamepad.leftThumbstick.yAxis.value,
                    deadzone: deadzone
                )
            }
            if cStickX == 0 && cStickY == 0 {
                (cStickX, cStickY) = Self.applyDeadzone(
                    x: gamepad.rightThumbstick.xAxis.value,
                    y: gamepad.rightThumbstick.yAxis.value,
                    deadzone: deadzone
                )
            }
        }

        // Recording mode: publish the pressed set to the recorder UI, but do
        // not send any controller input to the guest and do not fire hotkeys.
        if let recordingHandler {
            recordingHandler(Array(pressed))
            input.setControllerButtons(0)
            input.setControllerStick(x: 0, y: 0)
            input.setControllerCStick(x: 0, y: 0)
            onConnectionChange(controllerName)
            return
        }

        // Release the active hotkey once any of its buttons is up.
        if !activeHotkeyButtons.isEmpty {
            let stillHeld = activeHotkeyButtons.allSatisfy { raw in
                pressed.contains { $0.rawValue == raw }
            }
            if !stillHeld {
                activeHotkeyButtons = []
            }
        }

        // Fire the longest matching 2–4 button combination once per hold.
        if activeHotkeyButtons.isEmpty {
            let pressedRaw = Set(pressed.map { $0.rawValue })
            let matches = hotkeyMap
                .compactMap { action, buttons -> (HotkeyAction, [String])? in
                    guard let action = HotkeyAction(rawValue: action),
                          buttons.count >= 2, buttons.count <= 4,
                          buttons.allSatisfy({ pressedRaw.contains($0) }) else { return nil }
                    return (action, buttons)
                }
                .sorted { $0.1.count > $1.1.count }
            if let match = matches.first {
                activeHotkeyButtons = Set(match.1)
                onHotkey?(match.0)
            }
        }

        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            mask |= buttonMask(from: gamepad)
        }

        input.setControllerButtons(mask)
        input.setControllerStick(x: stickX, y: stickY)
        input.setControllerCStick(x: cStickX, y: cStickY)
        onConnectionChange(controllerName)
    }

    /// Radius below `deadzone` reports (0,0); above it the vector is rescaled so
    /// full deflection still reaches 1.0 on both sticks.
    private static func applyDeadzone(x: Float, y: Float,
                                      deadzone: Float) -> (Float, Float) {
        let magnitude = sqrt(x * x + y * y)
        guard magnitude > 0.0001 else { return (0, 0) }
        guard magnitude > deadzone else { return (0, 0) }
        let scaled = (magnitude - deadzone) / (1 - deadzone)
        let scale = scaled / magnitude
        return (x * scale, y * scale)
    }

    private func buttonMask(from gamepad: GCExtendedGamepad) -> UInt32 {
        var mask: UInt32 = 0
        for button in PhysicalControllerButton.allCases {
            guard Self.isPressed(button, on: gamepad) else { continue }
            // A triggered hotkey's buttons are never sent to the guest.
            if activeHotkeyButtons.contains(button.rawValue) { continue }
            let raw = buttonMap[button.rawValue]
            let action = raw.flatMap(GamepadAction.init(rawValue:)) ?? button.defaultAction
            mask |= action.buttonBit
        }
        return mask
    }

    private func pressedButtons(on gamepad: GCExtendedGamepad) -> Set<PhysicalControllerButton> {
        var set: Set<PhysicalControllerButton> = []
        for button in PhysicalControllerButton.allCases where Self.isPressed(button, on: gamepad) {
            set.insert(button)
        }
        return set
    }

    // MARK: - Physical input lookup

    private static func allInputs(of gamepad: GCExtendedGamepad) -> [GCControllerButtonInput] {
        var inputs: [GCControllerButtonInput] = [
            gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
            gamepad.leftShoulder, gamepad.rightShoulder,
            gamepad.leftTrigger, gamepad.rightTrigger,
            gamepad.dpad.up, gamepad.dpad.down, gamepad.dpad.left, gamepad.dpad.right
        ]
        inputs.append(gamepad.buttonMenu)
        if let options = gamepad.buttonOptions { inputs.append(options) }
        return inputs
    }

    private static func isPressed(_ button: PhysicalControllerButton,
                                  on gamepad: GCExtendedGamepad) -> Bool {
        switch button {
        case .a: return gamepad.buttonA.isPressed
        case .b: return gamepad.buttonB.isPressed
        case .x: return gamepad.buttonX.isPressed
        case .y: return gamepad.buttonY.isPressed
        case .l: return gamepad.leftShoulder.isPressed
        case .r: return gamepad.rightShoulder.isPressed
        case .zl: return gamepad.leftTrigger.isPressed
        case .zr: return gamepad.rightTrigger.isPressed
        case .start: return gamepad.buttonMenu.isPressed
        case .select: return gamepad.buttonOptions?.isPressed == true
        case .dpadUp: return gamepad.dpad.up.isPressed
        case .dpadDown: return gamepad.dpad.down.isPressed
        case .dpadLeft: return gamepad.dpad.left.isPressed
        case .dpadRight: return gamepad.dpad.right.isPressed
        }
    }
}
