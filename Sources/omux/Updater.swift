import Sparkle
import SwiftUI

/// Sparkle updates: a daily check of the appcast on omux.app, and Help › Check for Updates….
/// Only runs from an app bundle; `swift run` has no Info.plist for Sparkle to read.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    private init() {
        let inBundle = Bundle.main.bundleURL.pathExtension == "app" && !Persistence.isWorkspacePreview
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
