import Foundation
import Citadel
import NIOCore

/// Performs SFTP uploads over a single SSH connection. Runs off the main actor.
actor TransferEngine {
    /// One file to upload within a batch, tagged with the queue item's id so
    /// the caller can route status back to the right UI row.
    struct Item: Sendable {
        let id: String
        let fileURL: URL
    }

    private let chunkSize = 1 << 18 // 256 KiB

    /// Connect once, then upload every item, reporting status per item.
    /// A connection-level failure fails all not-yet-started items.
    func uploadBatch(
        items: [Item],
        server: SSHServer,
        remoteDir: String,
        mode: TransferMode,
        passphrase: String?,
        sshDirectoryURL: URL?,
        validator: TOFUHostKeyValidator,
        report: @Sendable @escaping (String, TransferStatus) -> Void
    ) async {
        guard !items.isEmpty else { return }
        for item in items { report(item.id, .connecting) }

        let client: SSHClient
        let sftp: SFTPClient
        do {
            let auth = try SSHKeyLoader.authenticationMethod(
                for: server, passphrase: passphrase, sshDirectoryURL: sshDirectoryURL
            )
            client = try await SSHClient.connect(
                host: server.resolvedHost,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
            sftp = try await client.openSFTP()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            for item in items { report(item.id, .failed(message)) }
            return
        }

        let resolvedDir = await resolveRemoteDir(remoteDir, sftp: sftp)
        await ensureDirectory(resolvedDir, sftp: sftp)

        for item in items {
            do {
                let outcome = try await upload(item.fileURL, into: resolvedDir, mode: mode, sftp: sftp) { fraction in
                    report(item.id, .transferring(fractionCompleted: fraction))
                }
                report(item.id, outcome)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                report(item.id, .failed(message))
            }
        }

        try? await sftp.close()
        try? await client.close()
    }

    // MARK: - Single file

    private func upload(
        _ fileURL: URL,
        into remoteDir: String,
        mode: TransferMode,
        sftp: SFTPClient,
        progress: @Sendable (Double) -> Void
    ) async throws -> TransferStatus {
        let fileName = fileURL.lastPathComponent
        let remotePath = joinRemote(remoteDir, fileName)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let localSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let localMtime = (attributes[.modificationDate] as? Date) ?? Date()

        if mode == .sync,
           let remote = try? await sftp.getAttributes(at: remotePath),
           let remoteSize = remote.size,
           remoteSize == localSize,
           let remoteMtime = remote.accessModificationTime?.modificationTime,
           remoteMtime >= localMtime {
            return .skipped
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw KeyLoadError.unreadable(fileURL.lastPathComponent)
        }
        defer { try? handle.close() }

        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        progress(localSize == 0 ? 1 : 0)
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var buffer = ByteBuffer()
            buffer.writeBytes(chunk)
            try await file.write(buffer, at: offset)
            offset += UInt64(chunk.count)
            progress(localSize == 0 ? 1 : Double(offset) / Double(localSize))
        }
        try await file.close()

        // Best-effort: preserve modification time so Sync mode is meaningful next run.
        var attrs = SFTPFileAttributes()
        attrs.accessModificationTime = .init(accessTime: Date(), modificationTime: localMtime)
        try? await sftp.setAttributes(at: remotePath, to: attrs)

        return .completed
    }

    // MARK: - Remote path helpers

    private func resolveRemoteDir(_ dir: String, sftp: SFTPClient) async -> String {
        var dir = dir.trimmingCharacters(in: .whitespaces)
        if dir.hasPrefix("~") {
            if let home = try? await sftp.getRealPath(atPath: ".") {
                dir = home + String(dir.dropFirst(1))
            } else {
                dir = String(dir.dropFirst(1))
            }
        }
        if dir.isEmpty { dir = "." }
        if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }

    /// `mkdir -p` over SFTP: create each path component, ignoring "already exists".
    private func ensureDirectory(_ dir: String, sftp: SFTPClient) async {
        guard dir != "." , dir != "/" else { return }
        let isAbsolute = dir.hasPrefix("/")
        let components = dir.split(separator: "/").map(String.init)
        var path = isAbsolute ? "" : "."
        for component in components {
            path = path.isEmpty ? "/\(component)" : "\(path)/\(component)"
            try? await sftp.createDirectory(atPath: path)
        }
    }

    private func joinRemote(_ dir: String, _ name: String) -> String {
        if dir == "." || dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}
