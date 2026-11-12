//
//  DiagnosticsReport.swift
//  3ds2apple
//
//  Diagnostics export: one text report with the build, device, runtime state,
//  first-run warm-up, pipeline cache and frame timings, followed by the app log
//  (previous and current session).
//
//  The report is also the on-device record of the settings that change runtime
//  behaviour (frame cap, render scale, screen layout, audio), so a device run
//  can be checked against what the UI said it would do.
//

import CoreGraphics
import Foundation
import UIKit

/// One 3DS screen as reported by the linked static library.
struct ZakuroScreen {
    let width: UInt32
    let height: UInt32

    init(which: UInt32) {
        width = zk_screen_width(which)
        height = zk_screen_height(which)
    }

    var label: String { "\(width) × \(height)" }

    /// Width / height. The known screens are 400x240 and 320x240; a zero size
    /// (no library) falls back to 4:3.
    var aspectRatio: CGFloat {
        guard height > 0 else { return 4.0 / 3.0 }
        return CGFloat(Int(width)) / CGFloat(Int(height))
    }
}

enum DiagnosticsExporter {
    /// Writes a report to a temporary file and returns it, or nil on failure.
    static func write(model: ROMSession, settings: AppSettings) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "3ds2apple-diagnostics-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try report(model: model, settings: settings).write(to: url, atomically: true, encoding: .utf8)
            AppLog.log("[3ds2apple] diagnostics exported: %@", filename)
            return url
        } catch {
            AppLog.log("[3ds2apple] diagnostics export failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// The two 3DS screens at the console's own resolution for the chosen
    /// layout/rotation, e.g. "480x400" for the stacked console turned sideways.
    private static func nativePixelSizeDescription(settings: AppSettings) -> String {
        let size = ScreenGeometry.nativePixelSize(
            layout: settings.screenLayout,
            rotation: settings.screenRotation
        )
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// The drawable the presenter renders into (the layout's own pixels times
    /// the render scale).
    private static func drawablePixelSizeDescription(model: ROMSession, settings: AppSettings) -> String {
        let size = ScreenGeometry.drawablePixelSize(
            layout: model.screenLayout,
            rotation: model.screenRotation,
            renderScale: CGFloat(settings.renderScale)
        )
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// The report text: a header with the current state and both session logs.
    static func report(model: ROMSession, settings: AppSettings) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let screen = UIScreen.main
        let timing = model.frameStats.timing
        let warmUp = model.warmUp
        let cache = model.pipelineCacheStats
        var header = """
        3ds2apple diagnostics
        date=\(Date())
        app=\(version) (\(build))
        device=\(device.model) · \(device.systemName) \(device.systemVersion)
        screen=\(Int(screen.bounds.width * screen.scale))x\(Int(screen.bounds.height * screen.scale)) @\(screen.scale)x
        phase=\(phaseDescription(model.phase))
        rom=\(model.lastROM?.name ?? "none")
        paused=\(model.isPaused ? 1 : 0)
        aot=\(model.aotStatus.label)
        display=\(model.displayPath.label)
        hardware=\(model.hardwareStatus)
        loop=\(model.frameLoopLabel)
        frame_cap=\(model.frameRateCapValue)
        screen_layout=\(model.screenLayout.rawValue)
        screen_rotation=\(model.screenRotation.rawValue)
        screen_aspect=\(settings.screenAspect.rawValue)
        integer_scale=\(settings.integerScale ? 1 : 0)
        render_scale=\(settings.renderScale)x
        presented_native_pixels=\(nativePixelSizeDescription(settings: settings))
        presented_drawable_pixels=\(drawablePixelSizeDescription(model: model, settings: settings))
        orientation=\(settings.orientation.rawValue)
        fps=\(String(format: "%.1f", model.frameStats.fps))
        frames=\(model.frameStats.frames)
        speed=\(String(format: "%.1f%%", model.frameStats.fps / 60.0 * 100))
        last_result=\(model.frameStats.lastResult)
        audio=\(model.audioState.label)
        audio_volume=\(String(format: "%.2f", settings.audioVolume))
        audio_muted=\(settings.audioMuted ? 1 : 0)
        audio_buffer_ms=\(String(format: "%.1f", settings.audioBuffer.duration * 1000))
        touch_controls=\(settings.showTouchControls ? 1 : 0)
        controls_opacity=\(String(format: "%.2f", settings.controlsOpacity))
        haptics=\(settings.haptics ? 1 : 0)
        custom_hud=\(settings.showCustomHUD ? 1 : 0)
        playback_speed=\(settings.playbackSpeed.rawValue)
        playback_speed_effective=\(model.effectivePlaybackSpeed)
        playback_speed_auto_reduced=\(model.playbackSpeedAutoReduced ? 1 : 0)
        warmup_enabled=\(model.graphicsWarmUpEnabled ? 1 : 0)
        system_metal_hud=\(settings.systemMetalHUD ? 1 : 0)
        system_metal_hud_build_enabled=\(model.buildEnablesSystemMetalHUD ? 1 : 0)
        \(L10n.diagnosticsLine)
        controller=\(model.controllerName ?? "none")
        warmup_outcome=\(warmUp.diagnosticsOutcome)
        warmup_frames=\(warmUp.frames)
        warmup_elapsed_s=\(String(format: "%.2f", warmUp.elapsedSeconds))
        warmup_max_frame_ms=\(String(format: "%.1f", warmUp.maxFrameMilliseconds))
        warmup_spike_frames=\(warmUp.spikeFrames)
        warmup_quiet_frames=\(warmUp.quietFrames)/\(warmUp.plan.requiredQuietFrames)
        warmup_limit_s=\(String(format: "%.0f", warmUp.plan.maximumSeconds))
        warmup_from_cached_pipelines=\(warmUp.plan.fromWarmCache ? 1 : 0)
        warmup_summary=\(warmUp.summary ?? "(not run)")
        pipeline_cache_dir=\(cache.directoryPath.isEmpty ? "unknown" : cache.directoryPath)
        pipeline_cache=\(cache.summary)
        pipeline_cache_files=\(cache.fileCount)
        pipeline_cache_bytes=\(cache.byteCount)
        timing_ms_total=\(String(format: "%.2f/%.2f/%.2f", timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last))
        timing_ms_run=\(String(format: "%.2f/%.2f/%.2f", timing.runFrame.average, timing.runFrame.maximum, timing.runFrame.last))
        timing_ms_present=\(String(format: "%.2f/%.2f/%.2f", timing.present.average, timing.present.maximum, timing.present.last))
        timing_ms_read_top=\(String(format: "%.2f/%.2f/%.2f", timing.topScreenRead.average, timing.topScreenRead.maximum, timing.topScreenRead.last))
        timing_ms_read_bottom=\(String(format: "%.2f/%.2f/%.2f", timing.bottomScreenRead.average, timing.bottomScreenRead.maximum, timing.bottomScreenRead.last))
        timing_ms_cgimage=\(String(format: "%.2f/%.2f/%.2f", timing.cgImage.average, timing.cgImage.maximum, timing.cgImage.last))
        timing_ms_audio=\(String(format: "%.2f/%.2f/%.2f", timing.audioPump.average, timing.audioPump.maximum, timing.audioPump.last))
        """
        header += "\n\n"
        return AppLog.shared.exportReport(header: header)
    }

    /// One line for the current session phase (also shown on the home page).
    static func phaseDescription(_ phase: ROMSession.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .importing(let name): return "importing \(name)"
        case .starting(let name): return "starting \(name)"
        case .preparing(let name): return "preparing graphics: \(name)"
        case .loaded(let name): return "loaded \(name)"
        case .failed(let message): return "failed: \(message)"
        case .finished(let message): return "finished: \(message)"
        }
    }

    /// zk_run_frame result codes — see ZK_FRAME_* in ios/ZakuroBridge.h.
    /// Shown in the status line, so the label is localized.
    static func frameResultLabel(_ result: Int32) -> String {
        switch result {
        case 0: return L10n.tr("completed")
        case 1: return L10n.tr("exited")
        case -1: return L10n.tr("faulted")
        case -2: return L10n.tr("bad handle")
        default: return "\(result)"
        }
    }
}
