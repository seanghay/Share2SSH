import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// macOS Share Extension entry point. Stages the shared files, then uploads
/// them directly over SFTP (using the key the main app shared via the App
/// Group), showing progress inline — without opening the main app.
final class ShareViewController: NSViewController {
    private let stagingID = UUID().uuidString
    private var stagedFiles: [URL] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        stageInputFiles { [weak self] in
            self?.presentUI()
        }
    }

    // MARK: Staging

    private func stageInputFiles(completion: @escaping () -> Void) {
        guard let dir = AppGroup.stagingURL(for: stagingID) else { completion(); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            copyFile(from: provider, into: dir) { url in
                if let url { lock.lock(); self.stagedFiles.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    private func copyFile(from provider: NSItemProvider, into dir: URL, completion: @escaping (URL?) -> Void) {
        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                var source: URL?
                if let url = item as? URL { source = url }
                else if let data = item as? Data { source = URL(dataRepresentation: data, relativeTo: nil) }
                completion(source.flatMap { Self.copy($0, into: dir) })
            }
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
            completion(url.flatMap { Self.copy($0, into: dir) })
        }
    }

    private static func copy(_ source: URL, into dir: URL) -> URL? {
        let name = uniqueName(source.lastPathComponent, in: dir)
        let destination = dir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
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
        let model = ShareModel(servers: AppGroup.readServerCache(), stagedFiles: stagedFiles)
        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        model.onCancel = { [weak self] in
            self?.cleanupStaging()
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Share2SSH", code: -1))
        }
        let hosting = NSHostingView(rootView: ShareView(model: model))
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
    }

    private func cleanupStaging() {
        if let dir = AppGroup.stagingURL(for: stagingID) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
