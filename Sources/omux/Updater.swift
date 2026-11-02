import Sparkle
import SwiftUI

/// Sparkle updates: a daily check of the appcast on omux.app, and Help › Check for Updates….
/// Only runs from an app bundle; `swift run` has no Info.plist for Sparkle to read. A build
/// without SUFeedURL (./build.sh --no-updates) never checks, so it isn't replaced by the release.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    private init() {
        let inBundle = Bundle.main.bundleURL.pathExtension == "app" && !Persistence.isWorkspacePreview
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(startingUpdater: inBundle, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func check() { controller.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}

/// The version shown in the sidebar footer, e.g. "0.8.0 (14) · a920b2f". Local builds from build.sh
/// and scripts/preview-workspace.sh record a build number that counts up on each build (OmuxBuild)
/// and the commit (OmuxCommit), with "+" for uncommitted changes.
enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let commit = Bundle.main.object(forInfoDictionaryKey: "OmuxCommit") as? String
    static let build = Bundle.main.object(forInfoDictionaryKey: "OmuxBuild") as? String

    static var label: String {
        let numbered = build.map { "\(version) (\($0))" } ?? version
        let base = Persistence.isWorkspacePreview ? "Dev \(numbered)" : Persistence.isBeta ? "Beta \(numbered)" : numbered
        return commit.map { "\(base) · \($0)" } ?? base
    }
}
