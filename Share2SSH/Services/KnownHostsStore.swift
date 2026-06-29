import Foundation
import NIOSSH
import NIOCore

/// Trust-on-first-use host key validator backed by `~/.ssh/known_hosts`.
///
/// Runs on the SSH event loop, so it must decide synchronously:
/// - host has known keys and the presented key matches → accept
/// - host has known keys but the key does NOT match → reject (possible MITM)
/// - host is unknown → accept on first use and record the key for appending
///
/// First-use acceptance is automatic (no blocking prompt mid-handshake); the
/// app surfaces "trusted new host <x>" afterwards.
nonisolated final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct HostKeyMismatch: Error, LocalizedError {
        let host: String
        var errorDescription: String? {
            "The host key for \(host) does not match a previously trusted key. This could indicate a man-in-the-middle attack. Remove the stale entry from ~/.ssh/known_hosts if the server key legitimately changed."
        }
    }

    let host: String
    let port: Int
    private let knownKeys: Set<NIOSSHPublicKey>
    private let lock = NSLock()
    private var _newlyAcceptedLine: String?

    /// known_hosts line to append after a successful first-use connection.
    var newlyAcceptedLine: String? {
        lock.lock(); defer { lock.unlock() }
        return _newlyAcceptedLine
    }

    init(host: String, port: Int, knownKeys: Set<NIOSSHPublicKey>) {
        self.host = host
        self.port = port
        self.knownKeys = knownKeys
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if knownKeys.isEmpty {
            let token = port == 22 ? host : "[\(host)]:\(port)"
            let line = token + " " + String(openSSHPublicKey: hostKey)
            lock.lock(); _newlyAcceptedLine = line; lock.unlock()
            validationCompletePromise.succeed(())
        } else if knownKeys.contains(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(HostKeyMismatch(host: host))
        }
    }
}

/// Reads and appends `~/.ssh/known_hosts`.
@MainActor
final class KnownHostsStore {
    static let shared = KnownHostsStore()
    private init() {}

    private var url: URL? {
        SecureBookmarkStore.shared.sshDirectoryURL?
            .appendingPathComponent("known_hosts")
    }

    /// Build a validator for a host, preloading its trusted keys.
    func makeValidator(host: String, port: Int) -> TOFUHostKeyValidator {
        TOFUHostKeyValidator(host: host, port: port, knownKeys: knownKeys(host: host, port: port))
    }

    /// Persist a freshly accepted host key line, if any.
    func commitIfNeeded(_ validator: TOFUHostKeyValidator) {
        guard let line = validator.newlyAcceptedLine else { return }
        append(line: line)
    }

    private func knownKeys(host: String, port: Int) -> Set<NIOSSHPublicKey> {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let matchTokens: Set<String> = port == 22 ? [host] : ["[\(host)]:\(port)"]
        var keys: Set<NIOSSHPublicKey> = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|") else { continue }
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count >= 3 else { continue }
            let hosts = fields[0].split(separator: ",").map(String.init)
            guard hosts.contains(where: { matchTokens.contains($0) }) else { continue }
            let openSSH = fields[1] + " " + fields[2]
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: openSSH) {
                keys.insert(key)
            }
        }
        return keys
    }

    private func append(line: String) {
        guard let url else { return }
        let entry = line.hasSuffix("\n") ? line : line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
        } else {
            // File may not exist yet.
            try? entry.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }
}
