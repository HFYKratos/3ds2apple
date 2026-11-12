//
//  AboutView.swift
//  3ds2apple
//
//  Version, runtime and licence information.
//

import Foundation
import SwiftUI
import UIKit

struct AboutView: View {
    @ObservedObject var model: ROMSession

    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("3ds2apple")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Nintendo 3DS games as native ARM64 apps on iPhone and iPad.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(versionLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }

            Section {
                infoRow(title: "Screens", value: "\(topScreen.label) · \(bottomScreen.label)")
                    .accessibilityIdentifier("zk-screen-width")
                infoRow(title: "AOT code", value: model.aotStatus.label)
                infoRow(title: "Presentation", value: model.displayPath.label)
                infoRow(title: "Frame loop", value: model.frameLoopLabel)
                if model.hardwareStatus != "—" {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Graphics")
                        Text(model.hardwareStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                infoRow(title: "Controller", value: model.controllerName ?? "Not connected")
            } header: {
                Text("Runtime")
            } footer: {
                Text("Games are recompiled ahead of time on a Mac with your own game dump; "
                     + "the app runs the AOT code and never enables a CPU JIT.")
            }

            Section {
                Text("This app ships without any game data. It has no ROMs, decryption keys, "
                     + "system files or game assets. Import only dumps that you made from a "
                     + "console you own.")
            } header: {
                Text("Your game")
            }

            Section {
                Text("Zakuro (MIT): 3DS runtime, services, GPU and interpreter fallback.")
                Text("3dsrecomp (MIT): ahead-of-time ARM/Thumb/VFP to C recompiler.")
                Text("Pocket Native (MIT): AOT linking and renderer reference.")
                Text("MoltenVK (Apache-2.0): Vulkan over Metal, used by the presented renderer.")
                Text("Azahar / Citra (GPLv3, behaviour reference only): emulation semantics "
                     + "references. No GPL code is linked into this app.")
            } header: {
                Text("Acknowledgements")
            }

            Section {
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
                infoRow(title: "Licence", value: "Apache-2.0")
                Text("Nintendo 3DS is a trademark of Nintendo Co., Ltd. This app is not "
                     + "affiliated with or endorsed by Nintendo.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) · build \(build)"
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
