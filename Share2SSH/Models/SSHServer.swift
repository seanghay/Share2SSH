import Foundation

/// How a file should be transferred to the remote.
enum TransferMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Straight SFTP upload, always overwrites the remote file.
    case copy
    /// SFTP upload that skips files whose remote size + mtime already match
    /// the local file. This is an honest stand-in for rsync — it is NOT a
    /// delta transfer (the sandbox has no `rsync` binary).
    case sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .sync: return "Sync (skip unchanged)"
        }
    }

    var subtitle: String {
        switch self {
        case .copy: return "Always upload and overwrite"
        case .sync: return "Skip files already up to date on the server"
        }
    }
}

/// A remote server the user can send files to.
///
/// Connection details (`host`, `user`, `port`, `identityFile`) mirror a `Host`
/// block in `~/.ssh/config` — that file is the source of truth. App-only
/// metadata (`defaultRemoteDir`, `defaultMode`) lives in a separate sidecar
/// because those keys do not exist in ssh config.
struct SSHServer: Codable, Identifiable, Hashable, Sendable {
    /// The `Host` alias from `~/.ssh/config`; also the stable identity.
    var alias: String
    /// `HostName` — the real address to connect to. Falls back to `alias`.
    var host: String
    var user: String
    var port: Int
    /// Path to the private key (`IdentityFile`). May contain `~`.
    var identityFile: String?

    // App-only metadata (sidecar, not ssh config):
    var defaultRemoteDir: String
    var defaultMode: TransferMode

    var id: String { alias }

    init(
        alias: String,
        host: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil,
        defaultRemoteDir: String = "~/",
        defaultMode: TransferMode = .copy
    ) {
        self.alias = alias
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.defaultRemoteDir = defaultRemoteDir
        self.defaultMode = defaultMode
    }

    /// The address actually used to open a connection.
    var resolvedHost: String { host.isEmpty ? alias : host }

    /// A user-facing summary such as `root@example.com:22`.
    var displaySummary: String { "\(user)@\(resolvedHost):\(port)" }
}
