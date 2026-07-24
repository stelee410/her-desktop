import AppKit
import Foundation

/// UI-facing state of the self-updater.
enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)              // current version
    case available(AppUpdater.Release) // a newer release is downloadable
    case downloading(Double)           // 0…1
    case installing
    case failed(String)
}

@MainActor
extension AppViewModel {
    var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Ask GitHub for the latest release. `userInitiated` surfaces the
    /// "already up to date" / error outcomes; a background check stays quiet
    /// unless there's actually an update to offer.
    func checkForUpdates(userInitiated: Bool) async {
        // Don't stomp an in-flight download/install with a background poll.
        switch updateState {
        case .downloading, .installing: return
        default: break
        }
        if userInitiated { updateState = .checking }
        do {
            let release = try await AppUpdater.fetchLatestRelease(session: urlSession)
            if AppUpdater.isNewer(release.version, than: currentAppVersion) {
                updateState = .available(release)
            } else if userInitiated {
                updateState = .upToDate(currentAppVersion)
            } else {
                updateState = .idle
            }
        } catch {
            if userInitiated { updateState = .failed(error.localizedDescription) }
        }
    }

    /// Download the available release's DMG, verify it, and hand off to the
    /// helper that swaps the bundle and relaunches once we quit.
    func downloadAndInstallUpdate() async {
        guard case .available(let release) = updateState else { return }
        updateState = .downloading(0)
        let destination = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            let dmg = try await AppUpdater.downloadDMG(release, session: urlSession) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.updateState {
                        self.updateState = .downloading(fraction)
                    }
                }
            }
            updateState = .installing
            audit(type: "update.installing", summary: "Installing update \(release.version).")
            try await Task.detached(priority: .userInitiated) {
                try AppUpdater.stageAndScheduleInstall(dmgPath: dmg, destination: destination, appPID: pid)
            }.value
            // Let the helper start waiting, then quit so it can swap us out.
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
            audit(type: "update.failed", summary: error.localizedDescription)
        }
    }
}
