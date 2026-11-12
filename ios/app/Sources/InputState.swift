//
//  InputState.swift
//  3ds2apple
//
//  I3-T1: thread-safe input aggregation (on-screen controls + GameController)
//  and the button bit mapping for zk_set_input().
//
//  The on-screen controls and the controller handlers write on the main
//  thread; the frame loop reads exactly one snapshot on the runtime serial
//  queue immediately before zk_run_frame(). Every access goes through `lock`.
//

import Foundation

/// 3DS HID button bits, taken straight from ZK_BUTTON_* in ios/ZakuroBridge.h
/// so the Swift side cannot drift from the C ABI.
enum ZKButton {
    static let a = UInt32(ZK_BUTTON_A)
    static let b = UInt32(ZK_BUTTON_B)
    static let select = UInt32(ZK_BUTTON_SELECT)
    static let start = UInt32(ZK_BUTTON_START)
    static let right = UInt32(ZK_BUTTON_RIGHT)
    static let left = UInt32(ZK_BUTTON_LEFT)
    static let up = UInt32(ZK_BUTTON_UP)
    static let down = UInt32(ZK_BUTTON_DOWN)
    static let r = UInt32(ZK_BUTTON_R)
    static let l = UInt32(ZK_BUTTON_L)
    static let x = UInt32(ZK_BUTTON_X)
    static let y = UInt32(ZK_BUTTON_Y)
    static let zl = UInt32(ZK_BUTTON_ZL)
    static let zr = UInt32(ZK_BUTTON_ZR)
}

/// Immutable per-frame input snapshot, passed to zk_set_input().
struct InputSnapshot {
    /// ZK_BUTTON_* bit mask.
    var buttons: UInt32 = 0
    /// Circle Pad, -1.0 ... 1.0, +x right / +y up.
    var circleX: Float = 0
    var circleY: Float = 0
    /// Touchscreen contact in lower-screen pixels.
    var touch: Bool = false
    var touchX: UInt16 = 0
    var touchY: UInt16 = 0
}

/// Merges every input source into one snapshot.
final class InputState {
    private let lock = NSLock()

    /// Bits pressed on the on-screen controls.
    private var overlayButtons: UInt32 = 0
    /// Bits pressed on a connected hardware controller.
    private var controllerButtons: UInt32 = 0
    /// Left thumbstick, -1.0 ... 1.0.
    private var controllerStickX: Float = 0
    private var controllerStickY: Float = 0
    /// Touchscreen contact in lower-screen pixels; nil = not touching.
    private var touchX: UInt16?
    private var touchY: UInt16?

    // MARK: - Sources (any thread)

    /// Set/clear one on-screen button bit.
    func setOverlayButton(_ bit: UInt32, pressed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if pressed {
            overlayButtons |= bit
        } else {
            overlayButtons &= ~bit
        }
    }

    /// Clears the on-screen buttons and the touchscreen contact (used when the
    /// overlay is hidden so nothing stays stuck down).
    func clearOverlay() {
        lock.lock()
        defer { lock.unlock() }
        overlayButtons = 0
        touchX = nil
        touchY = nil
    }

    /// Replaces the whole hardware-controller button mask.
    func setControllerButtons(_ buttons: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        controllerButtons = buttons
    }

    /// Left thumbstick vector, -1.0 ... 1.0.
    func setControllerStick(x: Float, y: Float) {
        lock.lock()
        defer { lock.unlock() }
        controllerStickX = x
        controllerStickY = y
    }

    /// Clears the controller contribution (disconnect / teardown).
    func clearController() {
        lock.lock()
        defer { lock.unlock() }
        controllerButtons = 0
        controllerStickX = 0
        controllerStickY = 0
    }

    /// Touchscreen contact in lower-screen pixels; nil releases it.
    func setTouch(x: UInt16?, y: UInt16?) {
        lock.lock()
        defer { lock.unlock() }
        touchX = x
        touchY = y
    }

    /// Clears every source.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        overlayButtons = 0
        controllerButtons = 0
        controllerStickX = 0
        controllerStickY = 0
        touchX = nil
        touchY = nil
    }

    // MARK: - Frame snapshot (runtime queue)

    /// Combined input for the frame that is about to run.
    func snapshot() -> InputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = InputSnapshot()
        snapshot.buttons = overlayButtons | controllerButtons
        snapshot.circleX = controllerStickX
        snapshot.circleY = controllerStickY
        if let touchX, let touchY {
            snapshot.touch = true
            snapshot.touchX = touchX
            snapshot.touchY = touchY
        }
        return snapshot
    }
}
