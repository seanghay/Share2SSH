import Foundation
import Combine
import Sparkle

/// Wraps Sparkle's updater so SwiftUI can drive "Check for Updates…".
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true begins the scheduled background update checks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
