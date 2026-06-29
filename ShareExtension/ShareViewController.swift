import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// macOS Share Extension entry point. Stages the shared files into the App
/// Group inbox, lets the user pick a server + mode, writes a job descriptor,
/// and activates the main app to perform the upload.
final class ShareViewController: NSViewController {
    private let jobID = UUID().uuidString
    private var stagedFileNames: [String] = []
    private var servers: [ServerCacheEntry] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        servers = AppGroup.readServerCache()
        stageInputFiles { [weak self] in
            self?.presentUI()
        }
    }

    // MARK: Staging

    private func stageInputFiles(completion: @escaping () -> Void) {
        guard let inbox = AppGroup.inboxURL(for: jobID) else { completion(); return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
            group.enter()
            copyFile(from: provider, into: inbox) { name in
                if let name {
                    lock.lock(); self.stagedFileNames.append(name); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    private func copyFile(
        from provider: NSItemProvider,
        into inbox: URL,
        completion: @escaping (String?) -> Void
    ) {
        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                var source: URL?
                if let url = item as? URL { source = url }
                else if let data = item as? Data {
                    source = URL(dataRepresentation: data, relativeTo: nil)
                }
                completion(source.flatMap { Self.copy($0, into: inbox) })
            }
            return
        }
        // Fallback: ask for a file representation of the item.
        provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
            completion(url.flatMap { Self.copy($0, into: inbox) })
        }
    }

    /// Copy a (possibly temporary) source file into the inbox, returning the
    /// stored file name. Must run synchronously while the source URL is valid.
    private static func copy(_ source: URL, into inbox: URL) -> String? {
        let name = uniqueName(source.lastPathComponent, in: inbox)
        let destination = inbox.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return name
        } catch {
            NSLog("Share2SSH ext: copy failed: \(error)")
            return nil
        }
    }

    private static func uniqueName(_ name: String, in dir: URL) -> String {
        var candidate = name.isEmpty ? "file" : name
        var index = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    // MARK: UI

    private func presentUI() {
        let model = ShareModel(servers: servers, fileCount: stagedFileNames.count)
        let root = ShareView(
            model: model,
            onSend: { [weak self] entry, mode, dir in self?.send(server: entry, mode: mode, remoteDir: dir) },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
    }

    // MARK: Completion

    private func send(server: ServerCacheEntry, mode: TransferMode, remoteDir: String) {
        let job = TransferJob(
            id: jobID, serverAlias: server.alias, mode: mode,
            remoteDir: remoteDir, fileNames: stagedFileNames
        )
        if let inbox = AppGroup.inboxURL(for: jobID),
           let data = try? JSONEncoder().encode(job) {
            try? data.write(to: inbox.appendingPathComponent(AppGroup.jobFileName), options: .atomic)
        }
        activateHostApp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        if let inbox = AppGroup.inboxURL(for: jobID) {
            try? FileManager.default.removeItem(at: inbox)
        }
        let error = NSError(domain: "Share2SSH", code: -1)
        extensionContext?.cancelRequest(withError: error)
    }

    private func activateHostApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: AppGroup.hostBundleID
        ) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
}
