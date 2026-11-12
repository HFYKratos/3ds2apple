//
//  ContentView.swift
//  3ds2apple
//
//  I1 shell skeleton: proves the SwiftUI shell boots and that the Zakuro iOS
//  static library (libzakuro_ios.a) is linked. There is deliberately no ROM
//  import yet, so the only runtime values shown come from
//  zk_screen_width() / zk_screen_height() — those calls are unresolved symbols
//  unless the static library really participates in the link.
//
//  I2 will add zk_create() + the frame loop; see docs/plan.md.
//

import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    /// Screen geometry is read once from the linked static library.
    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    /// Explicit internal init: the synthesized memberwise init would be
    /// file-private because the stored properties are private, and App.swift
    /// constructs ContentView() from another file.
    init() {}

    var body: some View {
        VStack(spacing: 16) {
            header
            runtimeCard
            noROMCard
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: logRuntimeProbe)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("3ds2apple")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityIdentifier("app-title")
            Text("Nintendo 3DS, natively on iPhone")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Zakuro runtime", systemImage: "cpu")
                .font(.headline)

            HStack {
                Text("Upper screen")
                Spacer()
                Text(topScreen.label)
                    .monospacedDigit()
            }
            HStack {
                Text("Lower screen")
                Spacer()
                Text(bottomScreen.label)
                    .monospacedDigit()
            }
            Text("zk_screen_width(0) = \(topScreen.width)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("zk-screen-width")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var noROMCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No ROM loaded", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("ROM import arrives in I2. This build links the runtime and boots "
                 + "the shell; no game data is bundled.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("no-rom-card")
    }

    private var footer: some View {
        Text("I1 · shell skeleton · interpreter only, no JIT")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Diagnostics

    /// One line in `idevicesyslog` that proves the static library was linked
    /// and called on device (I1 acceptance).
    private func logRuntimeProbe() {
        NSLog(
            "[3ds2apple] zk_screen_width(0)=%u zk_screen_height(0)=%u "
                + "zk_screen_width(1)=%u zk_screen_height(1)=%u",
            topScreen.width,
            topScreen.height,
            bottomScreen.width,
            bottomScreen.height
        )
    }
}

/// One 3DS screen as reported by the linked static library.
private struct ZakuroScreen {
    let width: UInt32
    let height: UInt32

    init(which: UInt32) {
        self.width = zk_screen_width(which)
        self.height = zk_screen_height(which)
    }

    var label: String { "\(width) × \(height)" }
}
