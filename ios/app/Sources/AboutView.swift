//
//  AboutView.swift
//  3ds2apple
//
//  Product information: the app icon, name, version and build, one-line
//  positioning, project links, acknowledgements and the legal notice. A compact
//  runtime card appears only while a game is loaded; the old technical rows
//  (AOT linking details, Metal backend, frame loop, screens, controller) were
//  removed in 0.1.2 because the diagnostics export carries them.
//

import Foundation
import SwiftUI
import UIKit

struct AboutView: View {
    @ObservedObject var model: ROMSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                if model.isRuntimeActive {
                    runtimeCard
                }
                linksCard
                acknowledgementsCard
                legalCard
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Product identity

    private var heroCard: some View {
        VStack(spacing: 10) {
            appIcon
            Text("3ds2apple")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Nintendo 3DS games as native ARM64 apps on iPhone and iPad.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(versionLabel)
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = Self.bundledAppIcon() {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                .accessibilityLabel(Text("3ds2apple"))
        } else {
            // A plain xcodebuild app has no icon files (scripts/package-ipa.sh
            // adds them), so keep the branded placeholder for those builds.
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.55, blue: 0.62),
                                Color(red: 0.06, green: 0.30, blue: 0.45),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }
            .frame(width: 88, height: 88)
            .accessibilityLabel(Text("3ds2apple"))
        }
    }

    // MARK: - Running state

    /// Shown only while a game is loaded: the live facts that are worth a look
    /// here. Everything else stays in the diagnostics export and the device log.
    private var runtimeCard: some View {
        card(title: "Runtime", systemImage: "cpu") {
            aboutRow("AOT code", model.aotStatus.title)
            Divider()
            aboutRow("Presentation", model.displayPath.title)
            Divider()
            aboutRow("FPS", model.fpsText)
        }
    }

    // MARK: - Project links

    private var linksCard: some View {
        card(title: "Links", systemImage: "link") {
            linkRow("Repository", "https://github.com/HFYKratos/3ds2apple")
            Divider()
            linkRow("Releases", "https://github.com/HFYKratos/3ds2apple/releases")
            Divider()
            linkRow("Issues", "https://github.com/HFYKratos/3ds2apple/issues")
            Divider()
            linkRow("README", readmeURLString)
            Divider()
            linkRow("Licence", "https://github.com/HFYKratos/3ds2apple/blob/main/LICENSE")
            Divider()
            linkRow("Third-party notices", "https://github.com/HFYKratos/3ds2apple/blob/main/THIRD_PARTY.md")
        }
    }

    /// The README link follows the table the app is showing.
    private var readmeURLString: String {
        L10n.currentLanguage == .simplifiedChinese
            ? "https://github.com/HFYKratos/3ds2apple/blob/main/README.zh-CN.md"
            : "https://github.com/HFYKratos/3ds2apple/blob/main/README.md"
    }

    // MARK: - Acknowledgements

    private var acknowledgementsCard: some View {
        card(title: "Acknowledgements", systemImage: "heart.text.square") {
            acknowledgement("Zakuro (MIT): 3DS runtime, HLE services and GPU.")
            acknowledgement("3dsrecomp (MIT): ahead-of-time ARM/Thumb/VFP to C recompiler.")
            acknowledgement("Pocket Native (MIT): AOT linking and renderer reference.")
            acknowledgement("MoltenVK (Apache-2.0): Vulkan over Metal, used by the presented renderer.")
            acknowledgement("idevice (MIT): usbmuxd / AFC device bridge used by tools/devpush.")
            acknowledgement("LLVM/Clang/LLD 23.1.6 (Apache-2.0 with LLVM exception): local GamePack build on Windows and Linux.")
            acknowledgement("Impactor / plumesign (MIT): signing and install on Windows.")
            acknowledgement("Avalonia 12 / .NET 10 (MIT): Windows launcher UI and runtime.")
            Text("Azahar / Citra (GPL, behaviour reference only): emulation semantics references; no GPL code is linked into this app.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: - Legal notice

    private var legalCard: some View {
        card(title: "Legal", systemImage: "checkmark.shield") {
            legalLine("Nintendo 3DS is a trademark of Nintendo Co., Ltd. This app is not affiliated with or endorsed by Nintendo.")
            legalLine("This app ships without any game data: no ROMs, decryption keys, system files or game assets. Use only game dumps you made from your own console.")
            legalLine("3ds2apple is free and open source under the Apache-2.0 licence; the bundled third-party components keep their own licences.")
        }
    }

    // MARK: - Building blocks

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

    @ViewBuilder
    private func linkRow(_ title: LocalizedStringKey, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack {
                    Text(title)
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func acknowledgement(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legalLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
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

    // MARK: - App icon

    /// The shipped app icon. scripts/package-ipa.sh copies the AppIcon PNGs to
    /// the bundle root and declares them in CFBundleIcons; a plain xcodebuild
    /// app has neither, so the hero falls back to the placeholder above.
    private static func bundledAppIcon() -> UIImage? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = Bundle.main.infoDictionary?[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else {
                continue
            }
            names.append(contentsOf: files.reversed())
        }
        names.append(contentsOf: [
            "AppIcon1024x1024",
            "AppIcon83.5x83.5@2x",
            "AppIcon76x76@2x",
            "AppIcon60x60@3x",
            "AppIcon60x60@2x",
            "AppIcon60x60",
            "AppIcon",
        ])
        for name in names {
            if let image = UIImage(named: name) {
                return image
            }
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }
}
