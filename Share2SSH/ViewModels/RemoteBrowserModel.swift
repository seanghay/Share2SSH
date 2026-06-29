import Foundation
import SwiftUI
import Combine

/// Drives the remote file explorer for one server over a persistent SFTP session.
@MainActor
final class RemoteBrowserModel: ObservableObject {
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var currentPath: String = ""
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var statusMessage: String?
    @Published var needsPassphrase = false
    @Published private(set) var isConnected = false
    @Published private(set) var download: DownloadProgress?

    struct DownloadProgress: Equatable {
        var fileName: String
        var received: UInt64
        var total: UInt64
        var bytesPerSecond: Double
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    private(set) var server: SSHServer
    private let session = RemoteBrowserSession()
    private let downloadCancel = CancellationFlags()
    private let downloadKey = "current"
    private var connected = false
    private var userDisconnected = false
    private var sessionPassphrase: String?

    /// Notifies the owning store when this server connects/disconnects.
    var onConnectionChange: ((String, Bool) -> Void)?

    init(server: SSHServer) {
        self.server = server
    }

    func updateServer(_ server: SSHServer) {
        self.server = server
    }

    /// Connect on first appearance, unless the user explicitly disconnected.
    func start() async {
        guard !userDisconnected, !isConnected else { return }
        await load(server.defaultRemoteDir)
    }

    /// Explicit (re)connect requested by the user.
    func connect() async {
        userDisconnected = false
        await load(currentPath.isEmpty ? server.defaultRemoteDir : currentPath)
    }

    func disconnect() async {
        userDisconnected = true
        await session.disconnect()
        connected = false
        setConnected(false)
        entries = []
        statusMessage = "Disconnected."
    }

    func stop() async {
        await session.disconnect()
        connected = false
        setConnected(false)
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnectionChange?(server.alias, value)
    }

    // MARK: Navigation

    func open(_ entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await load(entry.path)
    }

    func goUp() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func refresh() async {
        await load(currentPath.isEmpty ? server.defaultRemoteDir : currentPath)
    }

    private func load(_ path: String) async {
        guard await ensureConnected() else { return }
        isLoading = true
        error = nil
        do {
            let resolved = try await session.resolve(path)
            let listing = try await session.list(resolved)
            currentPath = resolved
            entries = listing
        } catch {
            self.error = describe(error)
        }
        isLoading = false
    }

    // MARK: Actions

    func makeDirectory(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, await ensureConnected() else { return }
        let path = currentPath.hasSuffix("/") ? currentPath + trimmed : currentPath + "/" + trimmed
        do {
            try await session.makeDirectory(at: path)
            await load(currentPath)
        } catch {
            self.error = describe(error)
        }
    }

    func delete(_ entry: RemoteEntry) async {
        do {
            try await session.remove(entry)
            await load(currentPath)
        } catch {
            self.error = describe(error)
        }
    }

    func download(_ entry: RemoteEntry, to localURL: URL) async {
        let total = entry.size ?? 0
        let start = Date()
        downloadCancel.clear(downloadKey)
        download = DownloadProgress(fileName: entry.name, received: 0, total: total, bytesPerSecond: 0)
        do {
            try await session.download(
                entry, to: localURL,
                onProgress: { [weak self] received in
                    Task { @MainActor in
                        guard let self, self.download != nil else { return }
                        let elapsed = Date().timeIntervalSince(start)
                        let speed = elapsed > 0 ? Double(received) / elapsed : 0
                        self.download = DownloadProgress(
                            fileName: entry.name, received: received, total: total, bytesPerSecond: speed
                        )
                    }
                },
                isCancelled: { [downloadCancel, downloadKey] in downloadCancel.isCancelled(downloadKey) }
            )
            download = nil
            statusMessage = "Downloaded \(entry.name)"
        } catch is DownloadCancelled {
            download = nil
            statusMessage = "Download cancelled."
        } catch {
            download = nil
            self.error = describe(error)
        }
    }

    func cancelDownload() {
        downloadCancel.cancel(downloadKey)
    }

    // MARK: Passphrase

    func submitPassphrase(_ passphrase: String, remember: Bool) async {
        sessionPassphrase = passphrase
        if remember { Keychain.setPassphrase(passphrase, for: server.alias) }
        needsPassphrase = false
        await load(server.defaultRemoteDir)
    }

    // MARK: Connection

    private func ensureConnected() async -> Bool {
        if connected { return true }
        let sshDirectoryURL = SecureBookmarkStore.shared.sshDirectoryURL
        let passphrase = sessionPassphrase ?? Keychain.passphrase(for: server.alias)

        do {
            _ = try SSHKeyLoader.authenticationMethod(
                for: server, passphrase: passphrase, sshDirectoryURL: sshDirectoryURL
            )
        } catch KeyLoadError.passphraseRequired {
            needsPassphrase = true
            return false
        } catch {
            self.error = describe(error)
            return false
        }

        let validator = KnownHostsStore.shared.makeValidator(
            host: server.resolvedHost, port: server.port
        )
        do {
            try await session.connect(
                server: server, passphrase: passphrase,
                sshDirectoryURL: sshDirectoryURL, validator: validator
            )
            KnownHostsStore.shared.commitIfNeeded(validator)
            if validator.newlyAcceptedLine != nil {
                statusMessage = "Trusted new host “\(server.resolvedHost)”."
            }
            connected = true
            setConnected(true)
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
