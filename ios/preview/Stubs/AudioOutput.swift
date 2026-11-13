//
//  AudioOutput.swift (preview stub)
//  3ds2apple UI preview
//
//  Mac Catalyst cannot compile the real AVAudioEngine path (
//  UnsafeMutableAudioBufferListPointer / AVAudioSession are iOS-only), and the
//  preview app never starts a console or plays audio. ios/preview/project.yml
//  excludes the real Sources/AudioOutput.swift and compiles this stub instead,
//  which keeps the same API surface ROMSession uses.
//

import Foundation

/// UI-facing audio state.
enum AudioState {
    case off
    case running
    case muted
    case failed(String)

    /// Stable English value for the diagnostics report and the device log.
    var label: String {
        switch self {
        case .off: return "off"
        case .running: return "on"
        case .muted: return "muted"
        case .failed: return "failed"
        }
    }

    /// Localized value for the status line.
    var title: String {
        switch self {
        case .off: return L10n.tr("off")
        case .running: return L10n.tr("on")
        case .muted: return L10n.tr("muted")
        case .failed: return L10n.tr("failed")
        }
    }

    /// Failure detail for the UI, nil unless the engine failed to start.
    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
}

/// Silent stand-in for the AVAudioEngine output used by ROMSession.
final class AudioOutput {
    private(set) var isMuted = false
    private var volume: Float = 1.0
    private var preferredBufferDuration: TimeInterval = 0.01
    var currentVolume: Float { volume }
    var currentBufferDuration: TimeInterval { preferredBufferDuration }
    var underrunFrames: Int { 0 }

    @discardableResult
    func startEngine() -> Bool { false }

    func stopEngine() {}

    func enqueue(_ samples: UnsafePointer<Int16>, frameCount: Int) {}

    func resetBuffer() {}

    func setMuted(_ muted: Bool) { isMuted = muted }

    func setVolume(_ newVolume: Float) { volume = newVolume }

    @discardableResult
    func setPreferredBufferDuration(_ seconds: TimeInterval) -> Bool {
        preferredBufferDuration = seconds
        return true
    }
}