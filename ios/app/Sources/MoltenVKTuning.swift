//
//  MoltenVKTuning.swift
//  3ds2apple
//
//  Developer A/B hook for MoltenVK's MVK_CONFIG_* performance parameters and
//  the renderer's own diagnostic switches.
//
//  Why an environment variable and not a Settings switch: MoltenVK reads these
//  once, while it makes its first Vulkan instance/device, which happens inside
//  the first presented game load. The shell already sets MTL_HUD_ENABLED and
//  XDG_CACHE_HOME at the same point (App.init), and a new Settings row would
//  still have to be applied before that first device. A launch environment
//  variable keeps the production behaviour unchanged (nothing is set unless the
//  tester opts in) while making a device/simulator A/B run possible without a
//  rebuild. See scripts/README.md §5.3 for the candidate matrix and the
//  measurement procedure.
//
//  0.1.3 adds *diagnostic GPU profiles* on top: a build can carry one profile
//  name in its Info.plist ("GPUDiagnosticsProfile", injected by
//  scripts/build-gpu-diagnostic-ipa.sh) and App.init applies that profile's
//  allow-listed MoltenVK parameters and renderer switches before the first
//  Vulkan device. A profile is what the GPU A/B IPAs differ in, so the same
//  binary code can be measured with and without a candidate optimisation; a
//  normal release build has no such key and the defaults are untouched.
//
//  Only names the pinned framework actually understands are accepted: the
//  supportedKeys list below was read from the MoltenVK 1.4.2 binary embedded in
//  the shell IPA (strings | grep MVK_CONFIG_), so a typo in an A/B run fails
//  loudly instead of being silently ignored. Nothing here is copied from
//  another project.
//

import Foundation

/// Applies allow-listed `MVK_CONFIG_*` environment variables and the renderer's
/// diagnostic switches before the first Vulkan device exists.
enum MoltenVKTuning {
    /// The `MVK_CONFIG_*` names the pinned MoltenVK 1.4.2 framework in the shell
    /// IPA understands (44 names; verified 2026-11-16 with `strings` on
    /// `Frameworks/MoltenVK.framework/MoltenVK`).
    static let supportedKeys: [String] = [
        "MVK_CONFIG_ACTIVITY_PERFORMANCE_LOGGING_STYLE",
        "MVK_CONFIG_ADVERTISE_EXTENSIONS",
        "MVK_CONFIG_ALLOW_METAL_EVENTS",
        "MVK_CONFIG_ALLOW_METAL_FENCES",
        "MVK_CONFIG_API_VERSION_TO_ADVERTISE",
        "MVK_CONFIG_AUTO_GPU_CAPTURE_OUTPUT_FILE",
        "MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE",
        "MVK_CONFIG_DEBUG",
        "MVK_CONFIG_DEFAULT_GPU_CAPTURE_SCOPE_QUEUE_FAMILY_INDEX",
        "MVK_CONFIG_DEFAULT_GPU_CAPTURE_SCOPE_QUEUE_INDEX",
        "MVK_CONFIG_DISPLAY_WATERMARK",
        "MVK_CONFIG_FAST_MATH_ENABLED",
        "MVK_CONFIG_FORCE_LOW_POWER_GPU",
        "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE",
        "MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES",
        "MVK_CONFIG_LOG_LEVEL",
        "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE",
        "MVK_CONFIG_METAL_COMPILE_TIMEOUT",
        "MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT",
        "MVK_CONFIG_PERFORMANCE_LOGGING_INLINE",
        "MVK_CONFIG_PERFORMANCE_TRACKING",
        "MVK_CONFIG_PREALLOCATE_DESCRIPTORS",
        "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS",
        "MVK_CONFIG_PRESENT_WITH_COMMAND_BUFFER",
        "MVK_CONFIG_RESUME_LOST_DEVICE",
        "MVK_CONFIG_SHADER_COMPRESSION_ALGORITHM",
        "MVK_CONFIG_SHADER_CONVERSION_FLIP_VERTEX_Y",
        "MVK_CONFIG_SHADER_DUMP_DIR",
        "MVK_CONFIG_SHADER_LOG_ESTIMATED_GLSL",
        "MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION",
        "MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES",
        "MVK_CONFIG_SUPPORT_LARGE_QUERY_POOLS",
        "MVK_CONFIG_SWAPCHAIN_MAG_FILTER_USE_NEAREST",
        "MVK_CONFIG_SWAPCHAIN_MIN_MAG_FILTER_USE_NEAREST",
        "MVK_CONFIG_SWITCH_SYSTEM_GPU",
        "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS",
        "MVK_CONFIG_TEXTURE_1D_AS_2D",
        "MVK_CONFIG_TIMESTAMP_PERIOD_LOWPASS_ALPHA",
        "MVK_CONFIG_TRACE_VULKAN_CALLS",
        "MVK_CONFIG_USE_COMMAND_POOLING",
        "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS",
        "MVK_CONFIG_USE_METAL_PRIVATE_API",
        "MVK_CONFIG_USE_MTLHEAP",
        "MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE",
    ]

    /// The renderer's own diagnostic switches a profile may set. They are read
    /// when the renderer or its device is built, inside the game load, so
    /// setting them at App.init is early enough. Every one is default-off or
    /// changes nothing unless the profile asks for it; ios/zakuro-ios/README.md
    /// describes what each one does.
    static let supportedRendererKeys: [String] = [
        "ZAKURO_GPU_TIMES",
        "ZAKURO_GPU_SHADERS",
        "ZAKURO_CPU_SHADERS",
        "ZAKURO_FAST_CLEARS",
        "ZAKURO_FAST_BARRIERS",
        "ZAKURO_SORT_OPAQUE",
        "ZAKURO_MERGE_PASSES",
        "ZAKURO_DEDUPE_CAPTURE",
        "ZAKURO_FLOAT_DEPTH",
        "ZAKURO_DEPTH_BLITS",
        "ZAKURO_STATIC_BLEND",
        "ZAKURO_GENERIC_SHADERS",
        "ZAKURO_INTERPRET_SHADERS",
        "ZAKURO_WAIT_FOR_SHADERS",
    ]

    /// `NAME=value` pairs separated by commas, e.g.
    /// `THREEDS2APPLE_MVK_CONFIG=MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`.
    static let environmentVariable = "THREEDS2APPLE_MVK_CONFIG"

    /// `NAME=value` pairs of the renderer's switches, applied like the MoltenVK
    /// ones. Only `supportedRendererKeys` are accepted.
    static let rendererEnvironmentVariable = "THREEDS2APPLE_RENDERER_OPTIONS"

    /// The diagnostic profile a build runs: `baseline`/`baseline2`, `mvk`,
    /// `renderer`, `sort` or `combo`, from this launch variable or the
    /// Info.plist key below. A normal build has neither.
    static let profileEnvironmentVariable = "THREEDS2APPLE_GPU_PROFILE"

    /// The Info.plist key scripts/build-gpu-diagnostic-ipa.sh writes into a
    /// diagnostic IPA to pick its profile; an explicit environment variable
    /// wins over it.
    static let profileInfoKey = "GPUDiagnosticsProfile"

    /// The profiles a diagnostic IPA can carry, in the order the build script
    /// makes them.
    static let profileNames = [
        "baseline", "baseline2", "baseline3", "mvk", "renderer", "sort", "sort2", "merge", "capture", "combo",
    ]

    /// The overrides actually applied, as `NAME=value`, for the log and the
    /// diagnostics report.
    private(set) static var applied: [String] = []

    /// The renderer switches actually applied, as `NAME=value`.
    private(set) static var rendererApplied: [String] = []

    /// The diagnostic profile this launch runs, none on a normal launch.
    private(set) static var profile: String?

    /// One line for the device log and the diagnostics report; says "none" on a
    /// normal launch so a captured report explains the framework defaults.
    static var diagnosticsLine: String {
        let moltenvk = applied.isEmpty ? "moltenvk_env=none" : "moltenvk_env=" + applied.joined(separator: ",")
        let renderer = rendererApplied.isEmpty ? "renderer_env=none" : "renderer_env=" + rendererApplied.joined(separator: ",")
        return "\(moltenvk) gpu_profile=\(profile ?? "none") \(renderer)"
    }

    /// What a diagnostic profile sets: MoltenVK parameters and renderer
    /// switches, as `NAME=value`. Unknown names set nothing.
    ///
    /// `baseline` is the first round's control: it measures the GPU's own
    /// execution time and changes nothing else. `baseline2` is the second
    /// round's control (pass attribution in the GPU line). `baseline3` is the
    /// third round's control: the same timing, plus the per-pass report (each
    /// pass's GPU milliseconds and draws, and what ended the pass before it),
    /// the pass-break reasons, the kinds of work started and the work
    /// operations per frame. `sort2` is `baseline3` plus the relaxed opaque
    /// front-to-back sort (`ZAKURO_SORT_OPAQUE=1`): its `sorted N/f of M/f`
    /// and reason counters say whether it engaged and why not. `merge` is
    /// `baseline3` plus render-pass merging (`ZAKURO_MERGE_PASSES=1`): a draw
    /// the guest gives no depth buffer, into the color buffer a depth-buffered
    /// pass is already drawing into, keeps that pass with its depth test and
    /// write off, so the pass does not end and begin again. `capture` is
    /// `baseline3` plus duplicate-capture skipping
    /// (`ZAKURO_DEDUPE_CAPTURE=1`). `mvk` adds the MoltenVK performance
    /// parameters an iPhone can use. `renderer` adds the renderer's 0.1.3
    /// A/B switches (image clears where they can be, a narrower barrier
    /// between render passes). `sort` is the second round's sort profile,
    /// kept so an old IPA can be compared on the same scene. `combo` is
    /// `mvk` + `renderer`, for the run after the A/B names a winner.
    static func profileOptions(_ name: String) -> (moltenvk: [String], renderer: [String]) {
        switch name {
        case "baseline", "baseline2", "baseline3":
            return ([], ["ZAKURO_GPU_TIMES=1"])
        case "sort", "sort2":
            return ([], ["ZAKURO_GPU_TIMES=1", "ZAKURO_SORT_OPAQUE=1"])
        case "merge":
            return ([], ["ZAKURO_GPU_TIMES=1", "ZAKURO_MERGE_PASSES=1"])
        case "capture":
            return ([], ["ZAKURO_GPU_TIMES=1", "ZAKURO_DEDUPE_CAPTURE=1"])
        case "mvk":
            return (
                [
                    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1",
                    "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1",
                    "MVK_CONFIG_USE_MTLHEAP=1",
                    "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=8",
                    "MVK_CONFIG_PRESENT_WITH_COMMAND_BUFFER=1",
                    "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0",
                ],
                ["ZAKURO_GPU_TIMES=1"]
            )
        case "renderer":
            return (
                [],
                [
                    "ZAKURO_GPU_TIMES=1",
                    "ZAKURO_FAST_CLEARS=1",
                    "ZAKURO_FAST_BARRIERS=1",
                ]
            )
        case "combo":
            return (
                profileOptions("mvk").moltenvk,
                profileOptions("mvk").renderer
                    + ["ZAKURO_FAST_CLEARS=1", "ZAKURO_FAST_BARRIERS=1"]
            )
        default:
            return ([], [])
        }
    }

    /// Reads the launch environment and the diagnostic profile once and calls
    /// `setenv` per allow-listed key. Called from `ThreeDS2AppleApp.init` before
    /// the first `zk_*` call can create a Vulkan device; a normal launch (no
    /// variable, no profile key) changes nothing.
    static func applyFromEnvironment() {
        guard applied.isEmpty && rendererApplied.isEmpty else { return }   // SwiftUI may rebuild the App.
        // 1) the diagnostic profile, an explicit launch variable winning over
        // the IPA's Info.plist.
        let environment = ProcessInfo.processInfo.environment
        let requested = environment[profileEnvironmentVariable]
            ?? (Bundle.main.object(forInfoDictionaryKey: profileInfoKey) as? String)
        if let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = requested.trimmingCharacters(in: .whitespaces).lowercased()
            if profileNames.contains(name) {
                profile = name
                let options = profileOptions(name)
                apply(pairs: options.moltenvk, keys: supportedKeys, into: &applied, source: "profile \(name)")
                apply(pairs: options.renderer, keys: supportedRendererKeys, into: &rendererApplied, source: "profile \(name)")
                AppLog.log("[3ds2apple] GPU diagnostic profile: %@ (%ld MoltenVK, %ld renderer switches)",
                           name, applied.count, rendererApplied.count)
            } else {
                AppLog.log("[3ds2apple] GPU diagnostic profile: refusing unknown profile %@ (known: %@)",
                           name, profileNames.joined(separator: ", "))
            }
        }
        // 2) explicit overrides last, so a tester can top a profile up without
        // a new build.
        let moltenvk = environment[environmentVariable] ?? ""
        apply(pairsCSV: moltenvk, keys: supportedKeys, into: &applied, source: environmentVariable)
        let renderer = environment[rendererEnvironmentVariable] ?? ""
        apply(pairsCSV: renderer, keys: supportedRendererKeys, into: &rendererApplied, source: rendererEnvironmentVariable)
        if applied.isEmpty {
            AppLog.log("[3ds2apple] MoltenVK tuning: no override applied (framework defaults)")
        } else {
            AppLog.log("[3ds2apple] MoltenVK tuning: applied %@ before the first device",
                       applied.joined(separator: ","))
        }
        if !rendererApplied.isEmpty {
            AppLog.log("[3ds2apple] Renderer tuning: applied %@ before the first device",
                       rendererApplied.joined(separator: ","))
        }
        AppLog.log("[3ds2apple] %@", diagnosticsLine)
    }

    /// Applies a comma separated `NAME=value` list, rejecting names not in
    /// `keys` and malformed pairs with a log line.
    private static func apply(pairsCSV raw: String, keys: [String], into target: inout [String], source: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        apply(pairs: trimmed.split(separator: ",").map(String.init), keys: keys, into: &target, source: source)
    }

    /// Applies `NAME=value` pairs through setenv, keeping the accepted ones.
    private static func apply(pairs: [String], keys: [String], into target: inout [String], source: String) {
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="), equals > trimmed.startIndex else {
                AppLog.log("[3ds2apple] GPU tuning (%@): ignoring malformed pair “%@”", source, trimmed)
                continue
            }
            let name = String(trimmed[..<equals])
            let value = String(trimmed[trimmed.index(after: equals)...])
            guard keys.contains(name) else {
                AppLog.log("[3ds2apple] GPU tuning (%@): refusing unknown key %@", source, name)
                continue
            }
            if target.contains(where: { $0.hasPrefix(name + "=") }) { continue }
            guard setenv(name, value, 1) == 0 else {
                AppLog.log("[3ds2apple] GPU tuning (%@): setenv(%@) failed", source, name)
                continue
            }
            target.append("\(name)=\(value)")
        }
    }
}
