//
//  CPUProfilerView.swift
//  3ds2apple
//
//  Debug page for the runtime's guest-PC sampling profiler
//  (zk_profiler_start / zk_profiler_hot_spots, ios/ZakuroBridge.h).
//
//  Sampling starts on demand and accumulates for the rest of the current game
//  load: the runtime adds a branch per guest step to record each PC, so this is
//  a diagnostic tool, not a setting. Samples are cumulative, never a recent
//  window, and the runtime cannot name guest functions: the hot spots are raw
//  guest addresses, resolved against a symbol map of the game's libgame.a.
//
//  The page is linked from Settings' Debug page. It only does anything while a
//  game is loaded: ROMSession queues every zk_* call on its runtime serial
//  queue and hands the copied text back to the main queue.
//

import SwiftUI

struct CPUProfilerView: View {
    @ObservedObject var model: ROMSession

    /// How many hot spots Refresh asks for; the runtime caps the count at 100.
    private static let hotSpotsCount: UInt32 = 20

    @State private var hotSpotsText = ""
    @State private var statusText = ""
    @State private var lastRefresh: Date?
    @State private var isRequestPending = false

    var body: some View {
        Form {
            samplingSection
            hotSpotsSection
            explanationSection
        }
        .navigationTitle("CPU Profiler")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("cpu-profiler")
    }

    // MARK: - Sampling

    private var samplingSection: some View {
        Section {
            if !model.isRuntimeLoaded {
                Label("Load a game first: sampling only works while a game is running.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button {
                startSampling()
            } label: {
                Label("Start sampling", systemImage: "play.circle")
            }
            .disabled(!model.isRuntimeLoaded || model.cpuProfilerStarted || isRequestPending)
            .accessibilityIdentifier("cpu-profiler-start")

            Button {
                refreshHotSpots()
            } label: {
                Label("Refresh hot spots", systemImage: "arrow.clockwise")
            }
            .disabled(!model.isRuntimeLoaded || isRequestPending)
            .accessibilityIdentifier("cpu-profiler-refresh")

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cpu-profiler-status")
            }
        } header: {
            Text("Sampling")
        } footer: {
            if model.cpuProfilerStarted {
                Text("Sampling is on. Reopen Settings later: the counts keep accumulating for this load.")
                    .font(.footnote)
            }
        }
    }

    // MARK: - Hot spots

    private var hotSpotsSection: some View {
        Section {
            if hotSpotsText.isEmpty {
                Text("No samples yet. Start sampling, play for a few seconds, then tap Refresh hot spots.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(hotSpotsText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("cpu-profiler-output")
            }
            if let lastRefresh {
                Text("Updated \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Hot spots")
        }
    }

    // MARK: - Explanation

    private var explanationSection: some View {
        Section {
            Text("Sampling is cumulative: every guest step since you tapped Start sampling contributes, so Refresh shows totals, not a recent window.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text("The runtime never names guest functions: hot spots are raw guest PCs (thread 0xPC hits). Match an address against the symbol map of the game's libgame.a (the AOT GamePack build); addresses from a different build of that pack will not match.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text("The profiler stays on for the current game load and adds a small cost per guest step; it is for diagnosis only. Unload the game or relaunch the app to stop it.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("About this profiler")
        }
    }

    // MARK: - Actions

    private func startSampling() {
        guard !isRequestPending else { return }
        isRequestPending = true
        statusText = ""
        model.startCPUProfiler { started in
            isRequestPending = false
            if started {
                statusText = "Sampling started. Play for a few seconds, then tap Refresh hot spots."
                refreshHotSpots()
            } else {
                statusText = "Could not start sampling (is a game running?)."
            }
        }
    }

    private func refreshHotSpots() {
        guard !isRequestPending else { return }
        isRequestPending = true
        model.cpuProfilerHotSpots(count: Self.hotSpotsCount) { text in
            isRequestPending = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            hotSpotsText = trimmed
            lastRefresh = Date()
            if trimmed.isEmpty && statusText.isEmpty {
                statusText = "No samples yet. Start sampling, play for a few seconds, then tap Refresh hot spots."
            }
        }
    }
}
