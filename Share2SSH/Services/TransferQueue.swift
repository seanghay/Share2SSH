import Foundation
import SwiftUI
import Combine

struct TransferItem: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let serverAlias: String
    let remoteDir: String
    let mode: TransferMode
    var status: TransferStatus
    /// Set when the item came from a Share Extension job, so we can clean up
    /// the inbox folder once the whole job finishes.
    var jobID: String?

    var fileName: String { fileURL.lastPathComponent }
}

struct PassphraseRequest: Identifiable, Sendable {
    let serverAlias: String
    var id: String { serverAlias }
}

/// Owns the list of transfers, schedules them connection-by-connection, and
/// drives passphrase prompts + known_hosts trust.
@MainActor
final class TransferQueue: ObservableObject {
    @Published private(set) var items: [TransferItem] = []
    @Published var passphraseRequest: PassphraseRequest?
    @Published var infoMessage: String?

    private let engine = TransferEngine()
    private let cancelFlags = CancellationFlags()
    private unowned let servers: ServerStore

    private var sessionPassphrases: [String: String] = [:]
    private var awaitingPassphrase: Set<String> = []
    private var processing = false

    init(servers: ServerStore) {
        self.servers = servers
    }

    // MARK: Enqueue

    func enqueue(files: [URL], server: SSHServer, mode: TransferMode, remoteDir: String) {
        let new = files.map {
            TransferItem(
                id: UUID().uuidString, fileURL: $0, serverAlias: server.alias,
                remoteDir: remoteDir, mode: mode, status: .queued, jobID: nil
            )
        }
        items.append(contentsOf: new)
        process()
    }

    /// Pick up a job written to the App Group inbox by the Share Extension.
    func enqueue(job: TransferJob) {
        guard let inbox = AppGroup.inboxURL(for: job.id) else { return }
        let urls = job.fileNames.map { inbox.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let new = urls.map {
            TransferItem(
                id: UUID().uuidString, fileURL: $0, serverAlias: job.serverAlias,
                remoteDir: job.remoteDir, mode: job.mode, status: .queued, jobID: job.id
            )
        }
        items.append(contentsOf: new)
        process()
    }

    func clearFinished() {
        for item in items where item.status.isTerminal { cancelFlags.clear(item.id) }
        items.removeAll { $0.status.isTerminal }
    }

    /// Cancel a queued or in-flight transfer.
    func cancel(_ item: TransferItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].status.isCancellable else { return }
        cancelFlags.cancel(item.id)
        // If it hasn't started yet, mark it now; in-flight items get reported
        // back as `.cancelled` by the engine.
        if case .queued = items[index].status {
            items[index].status = .cancelled
            cleanupJobIfFinished(items[index].jobID)
        }
    }

    // MARK: Passphrase

    func submitPassphrase(_ passphrase: String, remember: Bool, for alias: String) {
        sessionPassphrases[alias] = passphrase
        if remember { Keychain.setPassphrase(passphrase, for: alias) }
        awaitingPassphrase.remove(alias)
        passphraseRequest = nil
        process()
    }

    private func passphrase(for alias: String) -> String? {
        sessionPassphrases[alias] ?? Keychain.passphrase(for: alias)
    }

    // MARK: Scheduling

    private func process() {
        guard !processing else { return }
        processing = true
        Task { @MainActor in
            defer { processing = false }
            while let group = nextGroup() {
                await run(group)
            }
        }
    }

    /// Indices of the next runnable group of queued items that share a
    /// destination and whose server isn't waiting on a passphrase.
    private func nextGroup() -> [Int]? {
        guard let firstIndex = items.firstIndex(where: {
            if case .queued = $0.status { return !awaitingPassphrase.contains($0.serverAlias) }
            return false
        }) else { return nil }
        let key = items[firstIndex]
        let indices = items.indices.filter { index in
            guard case .queued = items[index].status else { return false }
            let item = items[index]
            return item.serverAlias == key.serverAlias
                && item.remoteDir == key.remoteDir
                && item.mode == key.mode
        }
        return indices
    }

    private func run(_ indices: [Int]) async {
        let alias = items[indices[0]].serverAlias
        let remoteDir = items[indices[0]].remoteDir
        let mode = items[indices[0]].mode

        guard let server = servers.server(withAlias: alias) else {
            for i in indices { items[i].status = .failed("Server “\(alias)” no longer exists.") }
            return
        }

        let sshDirectoryURL = SecureBookmarkStore.shared.sshDirectoryURL
        let pass = passphrase(for: alias)

        // Validate the key (and passphrase) before connecting.
        do {
            _ = try SSHKeyLoader.authenticationMethod(
                for: server, passphrase: pass, sshDirectoryURL: sshDirectoryURL
            )
        } catch KeyLoadError.passphraseRequired {
            awaitingPassphrase.insert(alias)
            passphraseRequest = PassphraseRequest(serverAlias: alias)
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            for i in indices { items[i].status = .failed(message) }
            return
        }

        let batch = indices.map { TransferEngine.Item(id: items[$0].id, fileURL: items[$0].fileURL) }
        let validator = KnownHostsStore.shared.makeValidator(host: server.resolvedHost, port: server.port)

        let report: @Sendable (String, TransferStatus) -> Void = { [weak self] id, status in
            Task { @MainActor in self?.apply(status, to: id) }
        }

        await engine.uploadBatch(
            items: batch, server: server, remoteDir: remoteDir, mode: mode,
            passphrase: pass, sshDirectoryURL: sshDirectoryURL, validator: validator,
            cancelFlags: cancelFlags, report: report
        )

        KnownHostsStore.shared.commitIfNeeded(validator)
        if validator.newlyAcceptedLine != nil {
            infoMessage = "Trusted new host “\(server.resolvedHost)” and added it to known_hosts."
        }
    }

    // MARK: Status updates

    private func apply(_ status: TransferStatus, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        if status.isTerminal { cleanupJobIfFinished(items[index].jobID) }
    }

    /// Once every item of a Share Extension job is terminal, remove its inbox.
    private func cleanupJobIfFinished(_ jobID: String?) {
        guard let jobID else { return }
        let jobItems = items.filter { $0.jobID == jobID }
        guard !jobItems.isEmpty, jobItems.allSatisfy({ $0.status.isTerminal }) else { return }
        if let inbox = AppGroup.inboxURL(for: jobID) {
            try? FileManager.default.removeItem(at: inbox)
        }
    }
}
