//
//  AboutView.swift
//  3ds2apple
//
//  Version, runtime and licence information in the same card style as the rest
//  of the shell.
//

import Foundation
import SwiftUI
import UIKit

struct AboutView: View {
    @ObservedObject var model: ROMSession

    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                runtimeCard
                gameCard
                acknowledgementsCard
                projectCard
                Text("Nintendo 3DS is a trademark of Nintendo Co., Ltd. This app is not affiliated with or endorsed by Nintendo.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.10, green: 0.55, blue: 0.62), Color(red: 0.06, green: 0.30, blue: 0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("3ds2apple")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Nintendo 3DS games as native ARM64 apps on iPhone and iPad.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(versionLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var runtimeCard: some View {
        card(title: "Runtime", systemImage: "cpu") {
            aboutRow("Screens", "\(topScreen.label) · \(bottomScreen.label)")
                .accessibilityIdentifier("zk-screen-width")
            Divider()
            aboutRow("AOT code", model.aotStatus.title)
            Divider()
            aboutRow("Presentation", model.displayPath.title)
            Divider()
            aboutRow("Frame loop", model.frameLoopDisplayLabel)
            if model.hardwareStatus != "—" {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Graphics")
                        .font(.subheadline)
                    Text(model.hardwareStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            aboutRow("Controller", model.controllerName ?? L10n.tr("Not connected"))
            Text("Games are recompiled ahead of time on a Mac with your own game dump; the app runs the AOT code and never enables a CPU JIT.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var gameCard: some View {
        card(title: "Your game", systemImage: "shield.lefthalf.filled") {
            Text("This app ships without any game data. It has no ROMs, decryption keys, system files or game assets. Import only dumps that you made from a console you own.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var acknowledgementsCard: some View {
        card(title: "Acknowledgements", systemImage: "heart.text.square") {
            acknowledgement("Zakuro (MIT): 3DS runtime, services, GPU and interpreter fallback.")
            acknowledgement("3dsrecomp (MIT): ahead-of-time ARM/Thumb/VFP to C recompiler.")
            acknowledgement("Pocket Native (MIT): AOT linking and renderer reference.")
            acknowledgement("MoltenVK (Apache-2.0): Vulkan over Metal, used by the presented renderer.")
            acknowledgement("Azahar / Citra (GPLv3, behaviour reference only): emulation semantics references. No GPL code is linked into this app.")
        }
    }

    private var projectCard: some View {
        card(title: "Project", systemImage: "link") {
            if let url = URL(string: "https://github.com/HFYKratos/3ds2apple") {
                Link(destination: url) {
                    HStack {
                        Text("Project page")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Divider()
            aboutRow("Licence", "Apache-2.0")
        }
    }

    private func card<Content: View>(title: LocalizedStringKey,
                                     systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func aboutRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func acknowledgement(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return L10n.format("Version %@ · build %@", version, build)
    }
}
