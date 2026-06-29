import Foundation

enum SSHConfigError: LocalizedError {
    case noAccess
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "Share2SSH doesn't have access to your ~/.ssh folder yet."
        case .writeFailed(let detail):
            return "Couldn't write ~/.ssh/config: \(detail)"
        }
    }
}

/// App-only per-server metadata that has no equivalent in `~/.ssh/config`.
private struct ServerMetadata: Codable {
    var defaultRemoteDir: String
    var defaultMode: TransferMode
}

/// Reads and writes the real `~/.ssh/config`, merging in app-only metadata and
/// keeping the App Group server cache up to date for the Share Extension.
@MainActor
final class SSHConfigManager {
    private let bookmarks = SecureBookmarkStore.shared

    private var sshDirectoryURL: URL? { bookmarks.sshDirectoryURL }
    private var configURL: URL? { sshDirectoryURL?.appendingPathComponent("config") }
    private var backupURL: URL? { sshDirectoryURL?.appendingPathComponent("config.share2ssh.bak") }

    // MARK: Reading

    func loadServers() throws -> [SSHServer] {
        guard sshDirectoryURL != nil else { throw SSHConfigError.noAccess }
        let file = try readConfigFile()
        let metadata = loadMetadata()
        var seen = Set<String>()
        let servers = file.servers.compactMap { server -> SSHServer? in
            // Drop duplicate Host blocks that share an alias (keep the first).
            guard seen.insert(server.alias).inserted else { return nil }
            var merged = server
            if let meta = metadata[server.alias] {
                merged.defaultRemoteDir = meta.defaultRemoteDir
                merged.defaultMode = meta.defaultMode
            }
            return merged
        }
        exportToAppGroup(servers)
        return servers
    }

    // MARK: Mutating

    func save(_ server: SSHServer, originalAlias: String? = nil) throws {
        guard sshDirectoryURL != nil else { throw SSHConfigError.noAccess }
        var file = try readConfigFile()
        // Handle a rename: drop the old alias block first.
        if let original = originalAlias, original != server.alias {
            file.remove(alias: original)
        }
        file.upsert(server)
        try writeConfigFile(file)

        var metadata = loadMetadata()
        if let original = originalAlias, original != server.alias {
            metadata[original] = nil
        }
        metadata[server.alias] = ServerMetadata(
            defaultRemoteDir: server.defaultRemoteDir,
            defaultMode: server.defaultMode
        )
        saveMetadata(metadata)

        _ = try loadServers() // refresh cache
    }

    func delete(alias: String) throws {
        guard sshDirectoryURL != nil else { throw SSHConfigError.noAccess }
        var file = try readConfigFile()
        file.remove(alias: alias)
        try writeConfigFile(file)

        var metadata = loadMetadata()
        metadata[alias] = nil
        saveMetadata(metadata)

        _ = try loadServers()
    }

    // MARK: App Group export (for the Share Extension)

    /// Write the enriched server cache (incl. private key text) and a copy of
    /// known_hosts so the sandboxed Share Extension can upload on its own.
    private func exportToAppGroup(_ servers: [SSHServer]) {
        let sshDirectoryURL = bookmarks.sshDirectoryURL
        let entries = servers.map { server in
            AppGroup.ServerCacheEntry(
                alias: server.alias,
                summary: server.displaySummary,
                host: server.resolvedHost,
                user: server.user,
                port: server.port,
                defaultRemoteDir: server.defaultRemoteDir,
                defaultMode: server.defaultMode,
                privateKey: SSHKeyLoader.rawKeyText(for: server, sshDirectoryURL: sshDirectoryURL)
            )
        }
        AppGroup.writeServerCache(entries)

        if let src = sshDirectoryURL?.appendingPathComponent("known_hosts"),
           let dst = AppGroup.knownHostsURL,
           let data = try? Data(contentsOf: src) {
            try? data.write(to: dst, options: .atomic)
        }
    }

    // MARK: Config file IO

    private func readConfigFile() throws -> SSHConfigFile {
        guard let url = configURL else { throw SSHConfigError.noAccess }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SSHConfigFile(preamble: [], blocks: [])
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return SSHConfigFile.parse(text)
    }

    private func writeConfigFile(_ file: SSHConfigFile) throws {
        guard let url = configURL, let backup = backupURL else { throw SSHConfigError.noAccess }
        // Back up the original once, before our first edit.
        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        do {
            try file.serialize().write(to: url, atomically: true, encoding: .utf8)
            // Keep ssh happy: config should be 0600.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            throw SSHConfigError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Metadata sidecar (app container, not ~/.ssh)

    private var metadataURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("Share2SSH", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata.json")
    }

    private func loadMetadata() -> [String: ServerMetadata] {
        guard let url = metadataURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: ServerMetadata].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveMetadata(_ metadata: [String: ServerMetadata]) {
        guard let url = metadataURL else { return }
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
