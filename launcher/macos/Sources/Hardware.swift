//
//  Hardware.swift
//  3ds2apple macOS launcher
//
//  What the compile step can use on this Mac (Windows launcher 0.2.4 parity).
//  3dsrecomp has no jobs flag: it derives its worker count from the logical CPU
//  count (std::thread::available_parallelism) and throttles clang invocations by
//  the free-memory budget, so the launcher only REPORTS the hardware and never
//  invents a compile-jobs setting. The Deploy page shows this line next to the
//  compile step and writes the same numbers to the log.
//

import Foundation
import Darwin

struct HardwareProfile: Equatable {
    /// Logical cores (what 3dsrecomp's available_parallelism reports).
    var logicalCores: Int
    /// Physical cores when the host can report them (never larger than logical).
    var physicalCores: Int
    /// Total physical memory in bytes.
    var totalMemoryBytes: UInt64

    /// Workers 3dsrecomp spawns for a foreground build (one per logical core).
    var compileJobs: Int { max(1, logicalCores) }

    /// Total physical memory in GiB (one decimal, invariant locale).
    var totalMemoryGB: Double { Double(totalMemoryBytes) / 1_073_741_824.0 }

    /// One-decimal GiB string without a locale thousands separator.
    var totalMemoryGBText: String {
        let formatted = String(format: "%.1f", totalMemoryGB)
        // "12.0" -> "12"; keep one decimal only when it carries information.
        if formatted.hasSuffix(".0") { return String(formatted.dropLast(2)) }
        return formatted
    }

    /// Compact engineering line used in logs and diagnostics.
    var describe: String {
        var text = String(logicalCores) + " logical / " + String(physicalCores)
        text += " physical cores · " + totalMemoryGBText + " GB RAM · "
        text += "3dsrecomp auto-parallelizes (" + String(compileJobs) + " jobs, memory-budgeted)"
        return text
    }

    /// Detect once per process; never throws (falls back to Foundation values).
    static func detect() -> HardwareProfile {
        let logical = logicalCoreCount()
        let physical = min(physicalCoreCount() ?? logical, max(1, logical))
        var memory = ProcessInfo.processInfo.physicalMemory
        if memory == 0 {
            memory = sysctlUInt64("hw.memsize") ?? 0
        }
        return HardwareProfile(
            logicalCores: max(1, logical),
            physicalCores: max(1, physical),
            totalMemoryBytes: memory
        )
    }

    /// Logical CPU count: sysctl hw.logicalcpu, with ProcessInfo as the fallback.
    static func logicalCoreCount() -> Int {
        if let value = sysctlInt("hw.logicalcpu"), value > 0 { return value }
        return max(1, ProcessInfo.processInfo.processorCount)
    }

    /// Physical CPU count: sysctl hw.physicalcpu (nil when the host cannot say).
    static func physicalCoreCount() -> Int? {
        guard let value = sysctlInt("hw.physicalcpu"), value > 0 else { return nil }
        return value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname(name, &value, &size, nil, 0)
        return status == 0 ? Int(value) : nil
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let status = sysctlbyname(name, &value, &size, nil, 0)
        return status == 0 ? value : nil
    }
}
