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

    let server: SSHServer
    private let session = RemoteBrowserSession()
    private var connected = false
    private var sessionPassphrase: String?

    init(server: SSHServer) {
        self.server = server
    }

    func start() async {
        await load(server.defaultRemoteDir)
    }

    func stop() async {
        await session.disconnect()
        connected = false
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
        do {
            try await session.download(entry, to: localURL)
            statusMessage = "Downloaded \(entry.name)"
        } catch {
            self.error = describe(error)
        }
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
