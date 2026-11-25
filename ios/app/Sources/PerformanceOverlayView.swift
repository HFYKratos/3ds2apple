import Foundation
import SwiftUI

/// Azahar-style performance overlay drawn over the game picture.
///
/// The lines are composed from the switches on the Performance overlay settings
/// page; a metric the platform cannot expose (battery temperature) is skipped
/// instead of showing a placeholder.
struct PerformanceOverlayView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings
    var isPreview: Bool = false

    var body: some View {
        if settings.performanceOverlayEnabled {
            let lines = performanceLines
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.94))
                .padding(settings.performanceOverlayBackground ? 7 : 0)
                .background {
                    if settings.performanceOverlayBackground {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.black.opacity(0.62))
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("performance-overlay")
                .accessibilityLabel(lines.joined(separator: ", "))
            }
        }
    }

    /// One line per group, ` | `-separated like the reference overlay. The
    /// memory line is separate so a narrow landscape stage can wrap it.
    private var performanceLines: [String] {
        var primary: [String] = []
        if settings.performanceOverlayShowFPS {
            let fps = isPreview ? 60 : Int(model.frameStats.fps.rounded())
            primary.append("FPS: \(fps)")
        }
        if settings.performanceOverlayShowFrameTime {
            let milliseconds = isPreview ? 4.2 : model.frameStats.timing.renderTotal.last
            primary.append(String(format: "Frame: %.1fms", milliseconds))
        }
        if settings.performanceOverlayShowSpeed {
            primary.append("Speed: \(isPreview ? "100%" : model.performanceSpeedText)")
        }
        var memory: [String] = []
        if settings.performanceOverlayShowProcessMemory,
           let bytes = PerformanceMetrics.residentMemoryBytes() {
            memory.append("Process RAM: \(PerformanceMetrics.megabytes(bytes)) MB")
        }
        if settings.performanceOverlayShowAvailableMemory,
           let bytes = PerformanceMetrics.availableMemoryBytes() {
            memory.append("Available RAM: \(PerformanceMetrics.megabytes(bytes)) MB")
        }
        if settings.performanceOverlayShowBatteryTemperature,
           let celsius = PerformanceMetrics.batteryTemperatureCelsius {
            let fahrenheit = celsius * 9 / 5 + 32
            memory.append(String(format: "%.1f°C / %.1f°F", celsius, fahrenheit))
        }
        return [primary.joined(separator: " | "), memory.joined(separator: " | ")]
            .filter { !$0.isEmpty }
    }
}

extension PerformanceOverlayPosition {
    /// SwiftUI alignment for the configured overlay corner.
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    /// True when the overlay sits in the lower half of the stage (the HUD uses
    /// a different bottom inset there).
    var isBottomRow: Bool {
        self == .bottomLeft || self == .bottomCenter || self == .bottomRight
    }
}
