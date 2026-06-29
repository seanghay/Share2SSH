import Foundation
import Citadel
import NIOCore

enum BrowserError: LocalizedError {
    case notConnected
    var errorDescription: String? { "Not connected to the server." }
}

/// Thrown to unwind a download that the user cancelled.
struct DownloadCancelled: Error {}

/// Holds an open SSH/SFTP connection for browsing a remote filesystem. One
/// session per server, reused across navigation/actions. Runs off the main actor.
actor RemoteBrowserSession {
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private let chunkSize = 1 << 18

    var isConnected: Bool { sftp != nil }

    func connect(
        server: SSHServer,
        passphrase: String?,
        sshDirectoryURL: URL?,
        validator: TOFUHostKeyValidator
    ) async throws {
        let auth = try SSHKeyLoader.authenticationMethod(
            for: server, passphrase: passphrase, sshDirectoryURL: sshDirectoryURL
        )
        let client = try await SSHClient.connect(
            host: server.resolvedHost,
            port: server.port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(validator),
            reconnect: .never
        )
        let sftp = try await client.openSFTP()
        self.client = client
        self.sftp = sftp
    }

    /// Run a small command to collect basic machine details. Best-effort.
    func fetchMachineInfo() async -> MachineInfo? {
        guard let client else { return nil }
        let command = """
        echo "host=$(hostname 2>/dev/null)"; \
        echo "kernel=$(uname -sr 2>/dev/null)"; \
        echo "arch=$(uname -m 2>/dev/null)"; \
        (. /etc/os-release 2>/dev/null; echo "os=${PRETTY_NAME}"); \
        echo "uptime=$(uptime -p 2>/dev/null)"; \
        echo "cpu=$(nproc 2>/dev/null)"; \
        echo "mem=$(free -h 2>/dev/null | awk '/Mem:/{print $2}')"
        """
        guard let buffer = try? await client.executeCommand(command, maxResponseSize: 64 * 1024) else {
            return nil
        }
        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
        let info = MachineInfo.parse(text)
        return info.isEmpty ? nil : info
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    /// Resolve `~`/relative paths to an absolute path on the server.
    func resolve(_ path: String) async throws -> String {
        guard let sftp else { throw BrowserError.notConnected }
        var path = path.trimmingCharacters(in: .whitespaces)
        if path.isEmpty || path == "~" {
            return try await sftp.getRealPath(atPath: ".")
        }
        if path.hasPrefix("~/") {
            let home = try await sftp.getRealPath(atPath: ".")
            path = home + "/" + String(path.dropFirst(2))
        }
        return (try? await sftp.getRealPath(atPath: path)) ?? path
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        guard let sftp else { throw BrowserError.notConnected }
        let names = try await sftp.listDirectory(atPath: path)
        let components = names.flatMap { $0.components }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        let entries: [RemoteEntry] = components.compactMap { component in
            let name = component.filename
            guard name != ".", name != ".." else { return nil }
            let isDir: Bool
            if let permissions = component.attributes.permissions {
                isDir = (permissions & 0o170000) == 0o040000
            } else {
                isDir = component.longname.hasPrefix("d")
            }
            return RemoteEntry(
                name: name,
                path: base.isEmpty ? "/\(name)" : "\(base)/\(name)",
                isDirectory: isDir,
                size: component.attributes.size,
                modified: component.attributes.accessModificationTime?.modificationTime
            )
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func makeDirectory(at path: String) async throws {
        guard let sftp else { throw BrowserError.notConnected }
        try await sftp.createDirectory(atPath: path)
    }

    func remove(_ entry: RemoteEntry) async throws {
        guard let sftp else { throw BrowserError.notConnected }
        if entry.isDirectory {
            try await sftp.rmdir(at: entry.path)
        } else {
            try await sftp.remove(at: entry.path)
        }
    }

    func download(
        _ entry: RemoteEntry,
        to localURL: URL,
        onProgress: @Sendable (UInt64) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws {
        guard let sftp else { throw BrowserError.notConnected }
        let total = (try? await sftp.getAttributes(at: entry.path).size) ?? 0
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw KeyLoadError.unreadable(localURL.lastPathComponent)
        }
        defer { try? handle.close() }

        let file = try await sftp.openFile(filePath: entry.path, flags: [.read])
        defer { Task { try? await file.close() } }

        var offset: UInt64 = 0
        var lastReport = Date.distantPast
        while true {
            if isCancelled() {
                try? handle.close()
                try? FileManager.default.removeItem(at: localURL) // drop the partial file
                throw DownloadCancelled()
            }
            let remaining = total > offset ? total - offset : UInt64(chunkSize)
            let length = UInt32(min(UInt64(chunkSize), remaining))
            let buffer = try await file.read(from: offset, length: length)
            if buffer.readableBytes == 0 { break }
            handle.write(Data(buffer.readableBytesView))
            offset += UInt64(buffer.readableBytes)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.15 {
                lastReport = now
                onProgress(offset)
            }
            if total > 0 && offset >= total { break }
        }
        onProgress(offset)
    }
}
