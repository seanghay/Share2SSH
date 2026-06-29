import SwiftUI
import Combine

/// Top-level state container. Owns the server store and the transfer queue and
/// routes incoming Share Extension jobs.
@MainActor
final class AppModel: ObservableObject {
    let servers = ServerStore()
    let browsers = BrowserStore()
    lazy var queue = TransferQueue(servers: servers)

    /// Jobs we've already enqueued this session, so repeated inbox scans (on
    /// every activation) don't double-enqueue.
    private var loadedJobs: Set<String> = []

    /// Pick up any jobs sitting in the App Group inbox. Called on launch and
    /// whenever the app becomes active (the Share Extension activates us after
    /// writing a job).
    func scanInbox() {
        guard let root = AppGroup.inboxRootURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
              ) else { return }
        for dir in entries where dir.hasDirectoryPath {
            loadJob(dir.lastPathComponent)
        }
    }

    private func loadJob(_ id: String) {
        guard !loadedJobs.contains(id) else { return }
        guard let inbox = AppGroup.inboxURL(for: id) else { return }
        let jobFile = inbox.appendingPathComponent(AppGroup.jobFileName)
        guard let data = try? Data(contentsOf: jobFile),
              let job = try? JSONDecoder().decode(TransferJob.self, from: data) else { return }
        loadedJobs.insert(id)
        queue.enqueue(job: job)
    }
}

@main
struct Share2SSHApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model.servers)
                .environmentObject(model.queue)
                .environmentObject(model.browsers)
                .onAppear { model.scanInbox() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in model.scanInbox() }
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
