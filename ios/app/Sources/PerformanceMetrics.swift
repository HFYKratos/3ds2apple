import Darwin
import Foundation

/// Live numbers for the in-game performance overlay.
///
/// Every accessor is optional: when the platform does not expose a metric the
/// overlay skips that line instead of printing a fake value (battery
/// temperature is the public example on iOS).
enum PerformanceMetrics {
    /// Resident memory of this process from Mach's task info. This is the
    /// "app memory usage" the overlay reports.
    static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size
    }

    /// Memory still available to this process (os_proc_available_memory).
    static func availableMemoryBytes() -> UInt64? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? UInt64(bytes) : nil
    }

    /// Public iOS APIs do not expose battery temperature. The settings row
    /// explains this and the overlay skips the line while it is nil.
    static var batteryTemperatureCelsius: Double? { nil }

    static func megabytes(_ bytes: UInt64) -> Int {
        Int(bytes / 1_048_576)
    }
}
