//
//  DiagnosticsReport.swift
//  3ds2apple
//
//  Diagnostics export: one text report with the build, device, runtime state,
//  pipeline cache and frame timings, followed by the app log (previous and
//  current session).
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

/// One diagnostics export: the share-sheet copy and the copy kept on the
/// device (visible in the Files app / pullable with `devpush get`).
struct DiagnosticsExport {
    /// Temporary file the share sheet shows (the pre-existing behaviour).
    let shareURL: URL
    /// `Documents/Diagnostics/<timestamp>.txt`, nil when it could not be written.
    let documentsURL: URL?
    /// Path relative to Documents for the UI hint, nil when not archived.
    let documentsPath: String?
}

enum DiagnosticsExporter {
    /// Diagnostics files kept in Documents/Diagnostics; older ones are pruned.
    static let retainedFiles = 5
    /// Subfolder of Documents the exports are kept in.
    static let folderName = "Diagnostics"

    /// Writes the report to a temporary file (share sheet) and keeps a copy in
    /// Documents/Diagnostics, so it can be taken from the Files app or pulled
    /// with `devpush get`. Returns nil only when the share-sheet copy fails; a
    /// failed on-device copy is logged and does not break the old flow.
    static func write(model: ROMSession, settings: AppSettings) -> DiagnosticsExport? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "3ds2apple-diagnostics-\(formatter.string(from: Date())).txt"
        let text = report(model: model, settings: settings)
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try text.write(to: temporaryURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("[3ds2apple] diagnostics export failed: %@", error.localizedDescription)
            return nil
        }
        AppLog.log("[3ds2apple] diagnostics exported: %@", filename)
        let keptURL = keepInDocuments(text: text, filename: filename)
        if let keptURL {
            AppLog.log("[3ds2apple] diagnostics kept (Files app → 3ds2apple → %@): %@",
                  folderName, keptURL.lastPathComponent)
        }
        return DiagnosticsExport(
            shareURL: temporaryURL,
            documentsURL: keptURL,
            documentsPath: keptURL.map { "\(folderName)/\($0.lastPathComponent)" }
        )
    }

    /// Writes one copy into Documents/Diagnostics and prunes the folder to the
    /// newest `retainedFiles` exports (the names sort by their timestamp).
    private static func keepInDocuments(text: String, filename: String) -> URL? {
        let fileManager = FileManager.default
        let folder = StorageInspector.documentsURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = uniqueURL(in: folder, filename: filename, fileManager: fileManager)
            try text.write(to: url, atomically: true, encoding: .utf8)
            prune(folder: folder, fileManager: fileManager)
            return url
        } catch {
            AppLog.log("[3ds2apple] diagnostics could not be kept on the device: %@",
                  error.localizedDescription)
            return nil
        }
    }

    /// Avoids overwriting an export made in the same second (`-2`, `-3`, ...).
    private static func uniqueURL(in folder: URL,
                                  filename: String,
                                  fileManager: FileManager) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    /// Keeps the newest `retainedFiles` exports (`yyyyMMdd-HHmmss` names sort
    /// chronologically).
    private static func prune(folder: URL, fileManager: FileManager) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        let diagnostics = names
            .filter { $0.hasPrefix("3ds2apple-diagnostics-") && $0.hasSuffix(".txt") }
            .sorted()
        for name in diagnostics.dropLast(retainedFiles) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The two 3DS screens at the console's own resolution for the chosen
    /// layout/rotation, e.g. "480x400" for the stacked console turned sideways.
    private static func nativePixelSizeDescription(settings: AppSettings) -> String {
        let size = ScreenGeometry.nativePixelSize(
            layout: settings.effectiveScreenLayout(isLandscape: false),
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
            renderScale: CGFloat(settings.clampedRenderScale)
        )
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// 1 when the loaded renderer measures its own GPU execution time (the
    /// diagnostic GPU profile set `ZAKURO_GPU_TIMES=1`), 0 otherwise.
    private static var gpuTimingEnabled: Bool {
        zk_gpu_timing_status() == 1
    }

    /// The GPU's real execution time per frame over the last 60-frame
    /// `zk_perf` window, in milliseconds, or why it is not measured.
    private static var gpuExecutionText: String {
        guard gpuTimingEnabled else { return "not measured (diagnostic GPU profile off)" }
        let micros = zk_gpu_exec_micros_per_frame()
        return String(format: "%.2f", Double(micros) / 1000.0)
    }

    /// The last window's full GPU breakdown (passes, barriers, draws, host
    /// waits, time per kind of work, shaded counts), or why it is not measured.
    private static var gpuTimesLine: String {
        guard gpuTimingEnabled else { return "not measured (diagnostic GPU profile off)" }
        var buffer = [CChar](repeating: 0, count: 1024)
        let written = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return zk_gpu_times_line(base, pointer.count)
        }
        guard written > 0 else { return "empty" }
        return String(cString: buffer)
    }
    /// The report text: a header with the current state and both session logs.
    static func report(model: ROMSession, settings: AppSettings) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let screen = UIScreen.main
        let timing = model.frameStats.timing
        let stutter = model.frameStats.stutter
        // Read the cache directory at export time with the same function the
        // AppLog lines use: the session snapshot only changes on a load or a
        // zk_destroy, so a report exported from a fresh app session used to say
        // `unknown`/`cold` while the app log named the directory and its files.
        let cache = PipelineCacheStats.read()
        let cacheAtLoad = model.pipelineCacheAtLoad
        let pauses = model.framePauseStats
        let aot = model.aotDiagnostics
        let aotPercentText = aot.aotPercent.map { String(format: "%.2f", $0) } ?? "-"
        let interpretedPercentText = aot.interpretedPercent.map { String(format: "%.2f", $0) } ?? "-"
        let fallbacksText = aot.instructionFallbacks.map(String.init) ?? "-"
        // Frame budget of a 60 Hz presentation, and each measured phase as a
        // share of the whole render work item. A single glance at the report
        // then says whether the frame is CPU-bound (run), presentation-bound
        // (present/read) or stalled on a pipeline compile (the max columns).
        let frameBudgetMs = 1000.0 / 60.0
        let renderTotalAvg = timing.renderTotal.average
        func share(_ milliseconds: Double) -> String {
            guard renderTotalAvg > 0 else { return "-" }
            return String(format: "%.1f", min(100, max(0, milliseconds / renderTotalAvg * 100)))
        }
        let screenReadAvg = timing.topScreenRead.average + timing.bottomScreenRead.average
        let budgetUsedText = renderTotalAvg > 0
            ? String(format: "%.1f", renderTotalAvg / frameBudgetMs * 100)
            : "-"
        var header = """
        3ds2apple diagnostics
        date=\(Date())
        app=\(version) (\(build))
        device=\(device.model) · \(device.systemName) \(device.systemVersion)
        screen=\(Int(screen.bounds.width * screen.scale))x\(Int(screen.bounds.height * screen.scale)) @\(screen.scale)x
        phase=\(phaseDescription(model.phase))
        game=\(model.currentGame.map { "\($0.title) (\($0.titleID))" } ?? "none")
        paused=\(model.isPaused ? 1 : 0)
        aot=\(model.aotStatus.label)
        aot_diagnostics=\(model.aotDiagnostics.label)
        aot_linked_code=\(model.aotDiagnostics.linkedCode ? 1 : 0)
        aot_recompiled=\(model.aotDiagnostics.recompiled ? 1 : 0)
        aot_recompiled_status=\(model.aotDiagnostics.status.isEmpty ? "-" : model.aotDiagnostics.status)
        aot_percent=\(aotPercentText)
        aot_interpreted_percent=\(interpretedPercentText)
        aot_fallbacks=\(fallbacksText)
        aot_pack=\(model.aotDiagnostics.packPath.isEmpty ? "none" : model.aotDiagnostics.packPath)
        metal_moltenvk_embedded=\(MetalBackend.isMoltenVKEmbedded ? 1 : 0)
        metal_hud_enabled=\(model.isSystemMetalHUDEnabled ? 1 : 0)
        renderer_software=\(model.displayPath == .metalDirect ? 0 : 1)
        display=\(model.displayPath.label)
        hardware=\(model.hardwareStatus)
        loop=\(model.frameLoopLabel)
        frame_cap=\(model.frameRateCapValue)
        screen_layout=\(model.screenLayout.rawValue)
        screen_rotation=\(model.screenRotation.rawValue)
        screen_aspect=\(settings.screenAspect.rawValue)
        integer_scale=\(settings.integerScale ? 1 : 0)
        render_scale=\(settings.clampedRenderScale)x
        render_scale_applies=next_load
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
        screen_layout_mode=\(settings.screenLayoutMode.rawValue)
        custom_screen_layout=\(settings.usesCustomScreenLayout ? 1 : 0)
        control_layout_mode=\(settings.controlLayoutMode.rawValue)
        control_layout_portrait_version=\(settings.storedControlLayout(for: .portrait).version)
        control_layout_landscape_version=\(settings.storedControlLayout(for: .landscape).version)
        playback_speed=\(settings.playbackSpeed.rawValue)
        playback_speed_effective=\(model.effectivePlaybackSpeed)
        playback_speed_auto_reduced=\(model.playbackSpeedAutoReduced ? 1 : 0)
        fps_counter=\(settings.showFPS ? 1 : 0)
        warmup_enabled=0
        warmup_note=removed-in-0.1.1 (the optional first-load graphics warm-up was removed; pipeline-cache persistence is unchanged)
        system_metal_hud=\(settings.systemMetalHUD ? 1 : 0)
        system_metal_hud_build_enabled=\(model.buildEnablesSystemMetalHUD ? 1 : 0)
        system_metal_hud_env=\(MetalHUD.isEnvironmentEnabled ? 1 : 0)
        system_metal_hud_plist=\(MetalHUD.buildGateEnabled ? 1 : 0)
        \(L10n.diagnosticsLine)
        controller=\(model.controllerName ?? "none")
        pipeline_cache_dir=\(cache.directoryPath.isEmpty ? "unknown" : cache.directoryPath)
        pipeline_cache_dir_state=\(cache.directoryState)
        pipeline_cache=\(cache.summary)
        pipeline_cache_files=\(cache.fileCount)
        pipeline_cache_bytes=\(cache.byteCount)
        pipeline_cache_at_load=\(cacheAtLoad.directoryPath.isEmpty ? "unknown (no load in this session)" : cacheAtLoad.summary)
        pipeline_cache_at_load_files=\(cacheAtLoad.fileCount)
        pipeline_cache_at_load_bytes=\(cacheAtLoad.byteCount)
        frame_pause_count=\(pauses.count)
        frame_pause_ms_total=\(String(format: "%.1f", pauses.totalMilliseconds))
        frame_pause_ms_last=\(String(format: "%.1f", pauses.lastMilliseconds))
        frame_pause_definition=paused wall time (software keyboard, in-game menu, save states, scene transitions) is excluded from fps, stutter and start-to-start timing; a pause stops or restarts the loop instead of counting as a frame
        timing_ms_total=\(String(format: "%.2f/%.2f/%.2f", timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last))
        timing_ms_run=\(String(format: "%.2f/%.2f/%.2f", timing.runFrame.average, timing.runFrame.maximum, timing.runFrame.last))
        timing_ms_run_gpu=\(String(format: "%.2f/%.2f/%.2f", timing.runGPU.average, timing.runGPU.maximum, timing.runGPU.last))
        timing_ms_run_cpu=\(String(format: "%.2f/%.2f/%.2f", timing.runCPU.average, timing.runCPU.maximum, timing.runCPU.last))
        timing_ms_interval=\(String(format: "%.2f/%.2f/%.2f", timing.frameInterval.average, timing.frameInterval.maximum, timing.frameInterval.last))
        timing_ms_present=\(String(format: "%.2f/%.2f/%.2f", timing.present.average, timing.present.maximum, timing.present.last))
        timing_ms_read_top=\(String(format: "%.2f/%.2f/%.2f", timing.topScreenRead.average, timing.topScreenRead.maximum, timing.topScreenRead.last))
        timing_ms_read_bottom=\(String(format: "%.2f/%.2f/%.2f", timing.bottomScreenRead.average, timing.bottomScreenRead.maximum, timing.bottomScreenRead.last))
        timing_ms_cgimage=\(String(format: "%.2f/%.2f/%.2f", timing.cgImage.average, timing.cgImage.maximum, timing.cgImage.last))
        timing_ms_audio=\(String(format: "%.2f/%.2f/%.2f", timing.audioPump.average, timing.audioPump.maximum, timing.audioPump.last))
        timing_share_run_pct=\(share(timing.runFrame.average))
        timing_share_run_gpu_pct=\(share(timing.runGPU.average))
        timing_share_run_cpu_pct=\(share(timing.runCPU.average))
        timing_share_present_pct=\(share(timing.present.average))
        timing_share_read_pct=\(share(screenReadAvg))
        timing_share_audio_pct=\(share(timing.audioPump.average))
        frame_budget_ms=\(String(format: "%.2f", frameBudgetMs))
        frame_budget_used_pct=\(budgetUsedText)
        \(stutterLines(stutter))
        perf_log=zk_perf window every 60 frames on stderr (ios/zakuro-ios/README.md)
        metal_moltenvk_env=\(MoltenVKTuning.diagnosticsLine)
        gpu_profile=\(MoltenVKTuning.profile ?? "none")
        gpu_profile_definition=diagnostic builds only (scripts/build-gpu-diagnostic-ipa.sh): baseline measures the GPU's own execution time and changes nothing else; baseline3 adds the third-round report (per-pass GPU time, draws and break reasons, work-operation counts); sort2 adds the relaxed opaque front-to-back sort with its sorted/draw/reason counters; merge adds render-pass merging (a depth-less draw into a depth-buffered pass keeps that pass); capture adds duplicate-capture skipping; mvk adds the MoltenVK performance parameters; renderer adds the 0.1.3 renderer A/B switches (image clears where they can be, a narrower barrier between render passes); combo both. none on a normal build
        gpu_timing_enabled=\(gpuTimingEnabled ? 1 : 0)
        gpu_exec_ms_per_frame=\(gpuExecutionText)
        gpu_exec_definition=real GPU execution time from the renderer's own Vulkan timestamp queries (ZAKURO_GPU_TIMES=1), averaged over the last 60-frame zk_perf window: the number the system Metal HUD shows as GPU time. timing_ms_run_gpu is the host command-walk time instead. A/B: compare this field, timing_ms_interval and a Metal HUD screenshot between profile IPAs in the same scene for the same duration
        gpu_times_line=\(gpuTimesLine)
        """
        header += "\n\n"
        return AppLog.shared.exportReport(header: header)
    }

    /// The stutter block of the header: thresholds, counters, per-phase
    /// attribution and the recent spikes (one line each).
    private static func stutterLines(_ stutter: StutterSnapshot) -> String {
        func share(_ phase: StutterPhase) -> String {
            String(format: "%.1f", stutter.share(for: phase))
        }
        var lines = [
            "stutter_definition=a presented frame the work item or a scheduling gap held over 33.3 ms (>100 ms severe); the gap is start-to-start minus the previous frame's work, so one hitch counts once (run-gpu: software GPU command walk / pipeline-compile suspect; run-cpu: emulated CPU/HLE; other: scheduling gap). Paused wall time (frame_pause_count/ms_total) is excluded: a pause stops or restarts the loop instead of counting as a frame.",
            "stutter_count=\(stutter.count)",
            "stutter_per_min=\(String(format: "%.2f", stutter.perMinute))",
            "stutter_severe_count=\(stutter.severeCount)",
            "stutter_worst_ms=\(String(format: "%.2f", stutter.worstMilliseconds))",
            "stutter_top_phase=\(stutter.count > 0 ? stutter.topPhase.label : "-")",
            "stutter_gpu_walk_bound_frames=\(stutter.gpuWalkBoundFrames)",
            "stutter_pipeline_compile_suspects=\(stutter.pipelineCompileSuspects)",
            "stutter_phase_share=run-gpu:\(share(.runGPU)),run-cpu:\(share(.runCPU)),present:\(share(.present)),read:\(share(.read)),cgImage:\(share(.cgImage)),audio:\(share(.audio)),other:\(share(.other))",
            "stutter_events=\(stutter.events.count) recent (t since loop start, interval = start to start, ms = how long the player was held up, work = measured work item, gpu = command walk inside it, phase, presented frame)"
        ]
        for event in stutter.events {
            lines.append(String(
                format: "stutter_event=t=%.3fs interval=%.2f ms=%.2f work=%.2f gpu=%.2f phase=%@ frame=%llu",
                event.atMilliseconds / 1000.0,
                event.intervalMilliseconds,
                event.milliseconds,
                event.workMilliseconds,
                event.gpuBusyMilliseconds,
                event.phase.label,
                event.frame
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// One line for the current session phase (also shown on the home page).
    static func phaseDescription(_ phase: ROMSession.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .starting(let name): return "starting \(name)"
        case .preparing(let name): return "preparing graphics: \(name)"
        case .loaded(let name): return "loaded \(name)"
        case .failed(let message): return "failed: \(message)"
        case .finished(let message): return "finished: \(message)"
        }
    }
}
