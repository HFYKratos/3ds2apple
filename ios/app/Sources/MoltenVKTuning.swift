//
//  MoltenVKTuning.swift
//  3ds2apple
//
//  Developer A/B hook for MoltenVK's MVK_CONFIG_* performance parameters.
//
//  Why an environment variable and not a Settings switch: MoltenVK reads these
//  once, while it makes its first Vulkan instance/device, which happens inside
//  the first presented game load. The shell already sets MTL_HUD_ENABLED and
//  XDG_CACHE_HOME at the same point (App.init), and a new Settings row would
//  still have to be applied before that first device. A launch environment
//  variable keeps the production behaviour unchanged (nothing is set unless the
//  tester opts in) while making a device/simulator A/B run possible without a
//  rebuild. See docs/performance.md §5.3 for the candidate matrix and the
//  measurement procedure.
//
//  Only names the pinned framework actually understands are accepted: the list
//  below was read from the MoltenVK 1.4.2 binary embedded in the shell IPA
//  (strings | grep MVK_CONFIG_), so a typo in an A/B run fails loudly instead of
//  being silently ignored. Nothing here is copied from another project.
//

import Foundation

/// Applies allow-listed `MVK_CONFIG_*` environment variables before the first
/// Vulkan device exists.
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

    /// `NAME=value` pairs separated by commas, e.g.
    /// `THREEDS2APPLE_MVK_CONFIG=MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`.
    static let environmentVariable = "THREEDS2APPLE_MVK_CONFIG"

    /// The overrides actually applied, as `NAME=value`, for the log and the
    /// diagnostics report.
    private(set) static var applied: [String] = []

    /// One line for the device log and the diagnostics report; says "none" on a
    /// normal launch so a captured report explains the framework defaults.
    static var diagnosticsLine: String {
        applied.isEmpty ? "moltenvk_env=none" : "moltenvk_env=" + applied.joined(separator: ",")
    }

    /// Reads the launch environment once and calls `setenv` per allow-listed
    /// key. Called from `ThreeDS2AppleApp.init` before the first `zk_*` call can
    /// create a Vulkan device; a normal launch (no variable) changes nothing.
    static func applyFromEnvironment() {
        guard applied.isEmpty else { return }   // SwiftUI may rebuild the App.
        guard let raw = ProcessInfo.processInfo.environment[environmentVariable],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            AppLog.log("[3ds2apple] MoltenVK tuning: %@ unset (framework defaults)", environmentVariable)
            return
        }
        var failures = 0
        for pair in raw.split(separator: ",") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="), equals > trimmed.startIndex else {
                failures += 1
                AppLog.log("[3ds2apple] MoltenVK tuning: ignoring malformed pair “%@”", String(trimmed))
                continue
            }
            let name = String(trimmed[..<equals])
            let value = String(trimmed[trimmed.index(after: equals)...])
            guard supportedKeys.contains(name) else {
                failures += 1
                AppLog.log("[3ds2apple] MoltenVK tuning: refusing unknown key %@", name)
                continue
            }
            guard setenv(name, value, 1) == 0 else {
                failures += 1
                AppLog.log("[3ds2apple] MoltenVK tuning: setenv(%@) failed", name)
                continue
            }
            applied.append("\(name)=\(value)")
        }
        if applied.isEmpty {
            AppLog.log("[3ds2apple] MoltenVK tuning: no valid override applied (%@ left at defaults)", environmentVariable)
        } else {
            AppLog.log("[3ds2apple] MoltenVK tuning: applied %@ before the first device (%ld rejected)",
                       applied.joined(separator: ","), failures)
        }
    }
}
