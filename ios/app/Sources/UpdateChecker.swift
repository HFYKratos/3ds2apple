//
//  UpdateChecker.swift
//  3ds2apple
//
//  GitHub release checker for the General page and the daily background update
//  notification (Stable/Beta channels). One request to the repository's
//  /releases endpoint; the newest matching non-draft release is compared with
//  this app's CFBundleShortVersionString.
//
//  Background policy: at most one automatic check per 24 hours (the timestamp
//  lives in UserDefaults), and a local notification is posted only when a newer
//  release is found and that version has not been announced yet. Local
//  notifications use UNUserNotificationCenter and ask for permission the first
//  time an update is available; no server/APNs involvement.
//

import Foundation
import UserNotifications

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case failed
    }

    @Published private(set) var status: Status = .idle

    /// Stable ignores pre-releases; Beta accepts the newest release including
    /// pre-release builds. Drafts are always skipped.
    func refresh(channel: UpdateChannel) async {
        status = .checking
        do {
            let release = try await latestRelease(channel: channel)
            let latest = release.version
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            status = Self.versionIsNewer(latest, than: current)
                ? .available(latest)
                : .upToDate(latest)
        } catch {
            AppLog.log("[3ds2apple] update check failed: %@", error.localizedDescription)
            status = .failed
        }
    }

    /// Called once when ContentView appears. It respects the Check for updates
    /// switch, the channel, and the 24-hour background limit.
    func backgroundCheckIfDue(settings: AppSettings) async {
        guard settings.checkForUpdates else { return }
        let last = defaults.object(forKey: Keys.lastBackgroundCheck) as? Date
        if let last, Date().timeIntervalSince(last) < Self.backgroundInterval {
            return
        }
        let channel = settings.updateChannel
        do {
            let release = try await latestRelease(channel: channel)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let isNewer = Self.versionIsNewer(release.version, than: current)
            defaults.set(Date(), forKey: Keys.lastBackgroundCheck)
            if isNewer {
                status = .available(release.version)
                await postNotificationIfNeeded(version: release.version)
            } else {
                status = .upToDate(release.version)
            }
        } catch {
            // A background failure must stay silent; the General page can retry.
            AppLog.log("[3ds2apple] background update check failed: %@", error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let prerelease: Bool
        let draft: Bool
    }

    private struct Release {
        let version: String
    }

    private func latestRelease(channel: UpdateChannel) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/HFYKratos/3ds2apple/releases?per_page=30") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let match = releases.first(where: { release in
            !release.draft && (channel == .beta || !release.prerelease)
        }) else {
            throw URLError(.resourceUnavailable)
        }
        let version = match.tag_name.hasPrefix("v")
            ? String(match.tag_name.dropFirst())
            : match.tag_name
        return Release(version: version)
    }

    // MARK: - Notification

    private func postNotificationIfNeeded(version: String) async {
        if defaults.string(forKey: Keys.lastNotifiedVersion) == version {
            return
        }
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        var authorized = current.authorizationStatus == .authorized
            || current.authorizationStatus == .provisional
            || current.authorizationStatus == .ephemeral
        if !authorized {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("Update available")
        content.body = L10n.format("3ds2apple %@ is available on GitHub.", version)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "3ds2apple-update-\(version)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            defaults.set(version, forKey: Keys.lastNotifiedVersion)
        } catch {
            AppLog.log("[3ds2apple] update notification failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Versions

    /// Numeric dotted-version comparison with a small pre-release ordering:
    /// 0.2.1 > 0.2.0, 0.2.0 > 0.2.0-beta2, and a missing pre-release part is
    /// newer than a present one. Build metadata (+...) is ignored.
    static func versionIsNewer(_ candidate: String, than current: String) -> Bool {
        func split(_ raw: String) -> (numbers: [Int], prerelease: [String]) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") { value.removeFirst() }
            if let plus = value.firstIndex(of: "+") {
                value = String(value[..<plus])
            }
            let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numeric = pieces.first.map { part in
                part.split(separator: ".").map { component in
                    Int(component.prefix(while: { $0.isNumber })) ?? 0
                }
            } ?? []
            let prerelease = pieces.count > 1
                ? pieces[1].split(separator: ".").map(String.init)
                : []
            return (numeric, prerelease)
        }
        let lhs = split(candidate)
        let rhs = split(current)
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left > right }
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return lhs.prerelease.isEmpty
        }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            let left = index < lhs.prerelease.count ? lhs.prerelease[index] : ""
            let right = index < rhs.prerelease.count ? rhs.prerelease[index] : ""
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber > rightNumber
            }
            return left > right
        }
        return false
    }

    // MARK: - Storage

    private enum Keys {
        static let lastBackgroundCheck = "UI.updateLastBackgroundCheck"
        static let lastNotifiedVersion = "UI.updateLastNotifiedVersion"
    }

    private static let backgroundInterval: TimeInterval = 24 * 60 * 60
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}