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

    // Citadel writes in 32 KB SFTP slices and awaits each one, so throughput is
    // latency-bound. We send one slice-sized chunk per task and keep many in
    // flight to pipeline them across the round-trip.
    private let chunkSize = 32_000
    private let maxInFlightWrites = 64

    private struct Cancelled: Error {}

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
        cancelFlags: CancellationFlags,
        report: @Sendable @escaping (String, TransferStatus) -> Void
    ) async {
        guard !items.isEmpty else { return }
        // Items cancelled before we even connect.
        let pending = items.filter { item in
            if cancelFlags.isCancelled(item.id) { report(item.id, .cancelled); return false }
            return true
        }
        guard !pending.isEmpty else { return }
        for item in pending { report(item.id, .connecting) }

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
            for item in pending { report(item.id, .failed(message)) }
            return
        }

        let resolvedDir = await resolveRemoteDir(remoteDir, sftp: sftp)
        await ensureDirectory(resolvedDir, sftp: sftp)

        for item in pending {
            if cancelFlags.isCancelled(item.id) {
                report(item.id, .cancelled)
                continue
            }
            do {
                let outcome = try await upload(
                    item.fileURL, into: resolvedDir, mode: mode, sftp: sftp,
                    itemID: item.id, cancelFlags: cancelFlags
                ) { status in
                    report(item.id, status)
                }
                report(item.id, outcome)
            } catch is Cancelled {
                report(item.id, .cancelled)
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
        itemID: String,
        cancelFlags: CancellationFlags,
        progress: @escaping @Sendable (TransferStatus) -> Void
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
        let meter = ProgressMeter(total: localSize, emit: progress)
        meter.emitInitial()

        var cancelledMidway = false
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var inFlight = 0
                var readOffset: UInt64 = 0
                while true {
                    if cancelFlags.isCancelled(itemID) { cancelledMidway = true; break }
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    let writeOffset = readOffset
                    readOffset += UInt64(chunk.count)
                    // Keep the pipeline full: once the window is saturated, wait
                    // for one write to land before queuing the next.
                    if inFlight >= maxInFlightWrites, let n = try await group.next() {
                        inFlight -= 1
                        meter.record(n)
                    }
                    group.addTask {
                        var buffer = ByteBuffer()
                        buffer.writeBytes(chunk)
                        try await file.write(buffer, at: writeOffset)
                        return chunk.count
                    }
                    inFlight += 1
                }
                if cancelledMidway { group.cancelAll() }
                while let n = try await group.next() { meter.record(n) }
            }
        } catch {
            if cancelledMidway {
                try? await file.close()
                try? await sftp.remove(at: remotePath)
                throw Cancelled()
            }
            throw error
        }

        if cancelledMidway {
            try? await file.close()
            try? await sftp.remove(at: remotePath) // delete the partial upload
            throw Cancelled()
        }

        try await file.close()
        meter.finish()

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

/// Thread-safe progress accumulator for pipelined writes. Coalesces the flood
/// of per-chunk completions into at most ~7 UI updates per second.
private final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private let start = Date()
    private let emit: @Sendable (TransferStatus) -> Void
    private var done: UInt64 = 0
    private var lastEmit = Date()

    init(total: UInt64, emit: @escaping @Sendable (TransferStatus) -> Void) {
        self.total = total
        self.emit = emit
    }

    func emitInitial() {
        emit(.transferring(
            fractionCompleted: total == 0 ? 1 : 0,
            bytesSent: 0, totalBytes: total, bytesPerSecond: 0
        ))
    }

    func record(_ bytes: Int) {
        lock.lock()
        done += UInt64(bytes)
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastEmit) >= 0.15
        if shouldEmit { lastEmit = now }
        let snapshot = done
        lock.unlock()
        if shouldEmit { fire(snapshot) }
    }

    func finish() {
        lock.lock(); let snapshot = done; lock.unlock()
        fire(snapshot)
    }

    private func fire(_ done: UInt64) {
        let elapsed = Date().timeIntervalSince(start)
        let speed = elapsed > 0 ? Double(done) / elapsed : 0
        let fraction = total == 0 ? 1 : min(1, Double(done) / Double(total))
        emit(.transferring(
            fractionCompleted: fraction, bytesSent: done,
            totalBytes: total, bytesPerSecond: speed
        ))
    }
}
