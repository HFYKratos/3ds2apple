//
//  GraphicsWarmUp.swift
//  3ds2apple
//
//  First-run graphics warm-up, pipeline-cache diagnostics and the state behind
//  the "Preparing graphics" overlay.
//
//  Background: the 3D is drawn through Vulkan (MoltenVK over Metal on iOS).
//  The first time a frame needs a GPU pipeline the driver compiles it, which
//  can take hundreds of milliseconds on a cold cache. The runtime compiles
//  pipelines on worker threads and draws through a generic fallback pipeline
//  meanwhile, but the fallback pipeline itself, the first program
//  translations and the cache write still land on the boot / first-screen
//  frames of a first run.
//
//  The app can therefore run a bounded number of frames behind an opaque
//  "Preparing graphics" overlay before revealing the game. This warm-up is
//  optional and off by default: a pipeline first used later still compiles on
//  a worker thread, so the loading wait was judged not worth it. The runtime's
//  pipeline-cache persistence (it writes the cache while the game runs) is
//  independent of this setting, so later loads start warm either way. When the
//  setting is on, the frames that compile and cache the warm pipelines are
//  never shown to the player; the run ends once consecutive frames are smooth
//  (no frame over `spikeMilliseconds`) or after a hard time limit. A button
//  lets the user skip it, and a later load of the same ROM (its pipelines
//  already saved on disk) uses a shorter limit.
//
//  Threading: `GraphicsWarmUpRun` is advanced only on the runtime serial
//  queue. `GraphicsWarmUpStatus` is the immutable snapshot copied to the main
//  queue for display; `PipelineCacheStats` only touches the filesystem.
//
//  Pipeline cache location: `App.swift` points `XDG_CACHE_HOME` at the app's
//  Caches directory before the runtime loads, and Zakuro keeps one file per
//  title in `Caches/zakuro/pipelines/<title-id>.bin`. Those files are
//  regenerable caches (iOS may purge Caches); they never contain game data
//  that is not already in the compile output.
//

import Foundation

/// Why a graphics warm-up run ended. Exported verbatim in diagnostics.
enum GraphicsWarmUpOutcome: String, Equatable {
    /// No warm-up has run yet.
    case notStarted = "not-started"
    /// The warm-up is running (only in the live state, never a final outcome).
    case running = "running"
    /// Consecutive frames were free of spikes: the game is revealed.
    case ready = "ready"
    /// The hard time limit was reached with frames still spiking; the game is
    /// revealed anyway (the limit is the bound on the loading wait).
    case maximumTime = "maximum-time"
    /// The user pressed Skip on the overlay.
    case skippedByUser = "skipped-by-user"
    /// The renderer fell back to software, so there are no GPU pipelines to
    /// warm; the warm-up is skipped and the game is revealed immediately.
    case skippedSoftware = "skipped-software-renderer"
    /// The optional warm-up setting is off (the default): the game is revealed
    /// as soon as zk_create succeeds. The runtime still writes its pipeline
    /// cache while the game runs, so later loads start from the same cache.
    case skippedDisabled = "skipped-disabled-setting"
    /// The runtime exited or faulted during the warm-up.
    case runtimeStopped = "runtime-stopped"

    /// Whether the game may be revealed (every outcome except running does).
    var revealsGame: Bool { self != .running }
}

/// Bounds for one warm-up run. A cold run covers a first run / cleared cache;
/// a warm-cache run is shorter because the pipelines are already on disk.
struct GraphicsWarmUpPlan: Equatable {
    /// Hard upper bound in seconds: the player never waits longer than this.
    var maximumSeconds: Double
    /// Lower bound in seconds: frames keep running behind the overlay at least
    /// this long, so a quiet streak between two boot phases does not end the
    /// warm-up before the second phase's first pipeline compile.
    var minimumSeconds: Double
    /// Consecutive frames without a spike that end the run.
    var requiredQuietFrames: Int
    /// A frame longer than this counts as a spike (a visible hitch).
    var spikeMilliseconds: Double
    /// Frames of boot work that always run, so the very first frames are never
    /// mistaken for a quiet run just because the title has not drawn yet.
    var minimumFrames: Int
    /// Whether this ROM's pipelines were already warmed in this app install.
    var fromWarmCache: Bool

    /// First run, or a cache that was cleared/updated: at least 2 s behind the
    /// loading screen (the background generic-pipeline pre-compile needs a few
    /// seconds) and up to 5 s, ending after 90 quiet frames in a row (about
    /// 1.5 s at 60 Hz) once that minimum has passed. A quiet stretch between
    /// two boot phases therefore cannot reveal the game just before the next
    /// compile burst.
    static let cold = GraphicsWarmUpPlan(
        maximumSeconds: 5,
        minimumSeconds: 2,
        requiredQuietFrames: 90,
        spikeMilliseconds: 50,
        minimumFrames: 30,
        fromWarmCache: false
    )

    /// A later load whose pipelines are on disk: the same spike test, but no
    /// minimum wait, a 2 s cap and 12 quiet frames (about 0.2 s): a cached load
    /// reveals the game in well under a second.
    static let warm = GraphicsWarmUpPlan(
        maximumSeconds: 2,
        minimumSeconds: 0,
        requiredQuietFrames: 12,
        spikeMilliseconds: 50,
        minimumFrames: 5,
        fromWarmCache: true
    )
}

/// One running warm-up. Mutated on the runtime queue only; the frame loop
/// records the duration of every frame it runs behind the overlay.
struct GraphicsWarmUpRun {
    let plan: GraphicsWarmUpPlan
    /// Persisted marker key: the ROM's relative path.
    let romKey: String
    let startedTicks: UInt64

    private(set) var frames = 0
    private(set) var quietFrames = 0
    private(set) var spikeFrames = 0
    private(set) var maxFrameMilliseconds: Double = 0
    private(set) var lastFrameMilliseconds: Double = 0
    private(set) var elapsedSeconds: Double = 0
    /// Set from the main queue through `ROMSession.skipGraphicsWarmUp()`.
    var skipRequested = false

    init(plan: GraphicsWarmUpPlan, romKey: String, startedTicks: UInt64) {
        self.plan = plan
        self.romKey = romKey
        self.startedTicks = startedTicks
    }

    /// Records one warm-up frame (milliseconds of `zk_run_frame` + presentation)
    /// and returns why the run should end, or nil while it should continue.
    mutating func record(frameMilliseconds: Double, nowTicks: UInt64) -> GraphicsWarmUpOutcome? {
        frames += 1
        lastFrameMilliseconds = frameMilliseconds
        maxFrameMilliseconds = max(maxFrameMilliseconds, frameMilliseconds)
        elapsedSeconds = FrameClock.seconds(nowTicks &- startedTicks)
        if frameMilliseconds > plan.spikeMilliseconds {
            spikeFrames += 1
            quietFrames = 0
        } else {
            quietFrames += 1
        }
        if skipRequested {
            return .skippedByUser
        }
        if frames >= plan.minimumFrames,
           quietFrames >= plan.requiredQuietFrames,
           elapsedSeconds >= plan.minimumSeconds {
            return .ready
        }
        if elapsedSeconds >= plan.maximumSeconds {
            return .maximumTime
        }
        return nil
    }

    /// The snapshot published to the main queue.
    func status(outcome: GraphicsWarmUpOutcome) -> GraphicsWarmUpStatus {
        GraphicsWarmUpStatus(
            isPreparing: outcome == .running,
            outcome: outcome,
            frames: frames,
            elapsedSeconds: elapsedSeconds,
            lastFrameMilliseconds: lastFrameMilliseconds,
            maxFrameMilliseconds: maxFrameMilliseconds,
            spikeFrames: spikeFrames,
            quietFrames: quietFrames,
            plan: plan
        )
    }
}

/// Immutable warm-up state shown by the UI and exported in diagnostics.
/// Built on the runtime queue, assigned on the main queue.
struct GraphicsWarmUpStatus: Equatable {
    var isPreparing = false
    var outcome: GraphicsWarmUpOutcome = .notStarted
    var frames = 0
    var elapsedSeconds: Double = 0
    var lastFrameMilliseconds: Double = 0
    var maxFrameMilliseconds: Double = 0
    var spikeFrames = 0
    var quietFrames = 0
    var plan = GraphicsWarmUpPlan.cold

    /// True while frames are being run behind the overlay.
    var isActive: Bool { outcome == .running }

    /// Live progress under the "Preparing graphics" title.
    var progressText: String {
        L10n.format(
            "%ld frames · %.1f s / %.0f s · max %.0f ms",
            frames,
            elapsedSeconds,
            plan.maximumSeconds,
            maxFrameMilliseconds
        )
    }

    /// One line for the status line / diagnostics once the run is over. Nil while a run
    /// is in progress and when the optional warm-up is off (the default), so a
    /// normal load adds no extra status line.
    var summary: String? {
        switch outcome {
        case .notStarted, .running, .skippedDisabled:
            return nil
        case .ready, .maximumTime, .skippedByUser, .runtimeStopped:
            var text = L10n.format(
                "warm-up %@ in %.2f s · %ld frames · max %.0f ms · %ld spiky (>%.0f ms)",
                outcome == .ready ? L10n.tr("ready") : L10n.tr("ended"),
                elapsedSeconds,
                frames,
                maxFrameMilliseconds,
                spikeFrames,
                plan.spikeMilliseconds
            )
            switch outcome {
            case .maximumTime:
                text = L10n.format(
                    "warm-up capped at %.0f s · %ld frames · max %.0f ms",
                    plan.maximumSeconds,
                    frames,
                    maxFrameMilliseconds
                )
            case .skippedByUser:
                text = L10n.format(
                    "warm-up skipped · %.1f s · %ld frames · max %.0f ms",
                    elapsedSeconds,
                    frames,
                    maxFrameMilliseconds
                )
            case .runtimeStopped:
                text = L10n.format(
                    "warm-up ended with the runtime · %.1f s · %ld frames",
                    elapsedSeconds,
                    frames
                )
            default:
                break
            }
            if plan.fromWarmCache {
                text += " · " + L10n.tr("cached pipelines")
            }
            return text
        case .skippedSoftware:
            return L10n.tr("warm-up not needed: the 3D draws in software (no GPU pipelines to compile)")
        }
    }

    /// Value for the diagnostics report's `warmup_outcome=` line.
    var diagnosticsOutcome: String { outcome.rawValue }

    /// The log line for `idevicesyslog` / the in-app log.
    var logLine: String {
        if let summary {
            return summary
        }
        if outcome == .skippedDisabled {
            return "warm-up skipped: the optional first-load warm-up is off"
        }
        return String(format: "warm-up running: %@", progressText)
    }

    /// Starts a run on the main queue (published immediately, before the loop).
    static func starting(plan: GraphicsWarmUpPlan) -> GraphicsWarmUpStatus {
        GraphicsWarmUpStatus(isPreparing: true, outcome: .running, plan: plan)
    }

    /// A run skipped because the renderer turned out to be software.
    static func skippedForSoftware() -> GraphicsWarmUpStatus {
        var status = GraphicsWarmUpStatus()
        status.outcome = .skippedSoftware
        return status
    }

    /// A run skipped because the optional warm-up setting is off (default).
    static func skippedForDisabledSetting() -> GraphicsWarmUpStatus {
        var status = GraphicsWarmUpStatus()
        status.outcome = .skippedDisabled
        return status
    }
}

/// Persisted "this ROM was warmed in this app install" marker. The stored
/// value includes the app version and build so an app update invalidates it
/// (a new build can compile different pipelines).
enum GraphicsWarmUpMarker {
    private static let keyPrefix = "I3.graphicsWarmUp."

    private static var buildToken: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version)/\(build)"
    }

    private static func key(for romKey: String) -> String {
        keyPrefix + romKey
    }

    /// Whether an earlier load of this ROM completed a full warm-up in this
    /// app install.
    static func wasCompleted(romKey: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: key(for: romKey)) else {
            return false
        }
        return stored == buildToken
    }

    static func markCompleted(romKey: String) {
        UserDefaults.standard.set(buildToken, forKey: key(for: romKey))
    }

    static func clear(romKey: String) {
        UserDefaults.standard.removeObject(forKey: key(for: romKey))
    }
}

/// One look at the pipeline cache directory Zakuro writes.
///
/// The cache is a regenerable cache, never game data; the app only reads its
/// file names/sizes for diagnostics (and to tell a cold first run from a
/// warmed one). If iOS purges the directory the stats simply read as cold and
/// the next load runs the full warm-up again.
struct PipelineCacheStats: Equatable {
    var fileCount = 0
    var byteCount: UInt64 = 0
    var newestFileName: String? = nil
    var newestModification: Date? = nil
    var directoryPath = ""

    static let empty = PipelineCacheStats()

    /// The app's Caches directory: what `XDG_CACHE_HOME` is set to before the
    /// runtime loads (App.swift). Zakuro appends `zakuro/pipelines`.
    static var cacheRootURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// `Caches/zakuro/pipelines`, where Zakuro keeps one `.bin` per title.
    static var directoryURL: URL? {
        cacheRootURL?.appendingPathComponent("zakuro/pipelines", isDirectory: true)
    }

    /// Whether any pipelines were kept from an earlier run.
    var isWarm: Bool { fileCount > 0 }

    /// Human-readable one-liner for logs and diagnostics.
    var summary: String {
        guard fileCount > 0 else {
            return "cold (no cached pipelines)"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        if let newestFileName, let newestModification {
            let stamp = PipelineCacheStats.dateFormatter.string(from: newestModification)
            return "\(files), \(size), newest \(newestFileName) at \(stamp)"
        }
        return "\(files), \(size)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Reads file count / total size / newest modification. Small directory:
    /// a handful of files, one per title. Never throws; a missing or
    /// unreadable directory reads as cold.
    static func read() -> PipelineCacheStats {
        guard let directory = directoryURL else { return .empty }
        var stats = PipelineCacheStats()
        stats.directoryPath = directory.path
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return stats
        }
        var newest: (name: String, date: Date)? = nil
        for entry in entries where entry.pathExtension.lowercased() == "bin" {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            stats.fileCount += 1
            if let size = values?.fileSize, size > 0 {
                stats.byteCount += UInt64(size)
            }
            if let date = values?.contentModificationDate {
                if newest == nil || date > newest!.date {
                    newest = (entry.lastPathComponent, date)
                }
            }
        }
        stats.newestFileName = newest?.name
        stats.newestModification = newest?.date
        return stats
    }
}
