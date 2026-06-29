import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

struct UploadProgress: Sendable {
    var index: Int
    var total: Int
    var fileName: String
    var fraction: Double
    var bytesPerSecond: Double
}

enum ShareUploadError: LocalizedError {
    case noKey
    case passphraseRequired
    case unsupportedKey(String)
    case keyParse(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No private key is available for this server. Open Share2SSH once so it can share the key."
        case .passphraseRequired:
            return "This server's key is passphrase-protected."
        case .unsupportedKey(let type):
            return "Unsupported key type \(type). ed25519 and RSA are supported."
        case .keyParse(let detail):
            return "Couldn't parse the private key: \(detail)"
        }
    }
}

/// Trust-on-first-use validator backed by the shared known_hosts copy.
nonisolated final class ExtHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Mismatch: Error {}
    private let knownKeys: Set<NIOSSHPublicKey>
    init(knownKeys: Set<NIOSSHPublicKey>) { self.knownKeys = knownKeys }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if knownKeys.isEmpty || knownKeys.contains(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Mismatch())
        }
    }
}

/// Standalone SFTP uploader for the Share Extension. Connects with the shared
/// key and uploads staged files with pipelined writes + progress reporting.
actor ShareUploader {
    private let chunkSize = 32_000
    private let maxInFlight = 48

    func upload(
        files: [URL],
        server: ServerCacheEntry,
        remoteDir: String,
        mode: TransferMode,
        passphrase: String?,
        knownHostsURL: URL?,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws {
        guard let keyText = server.privateKey, !keyText.isEmpty else { throw ShareUploadError.noKey }
        let auth = try makeAuth(user: server.user, keyText: keyText, passphrase: passphrase)
        let validator = ExtHostKeyValidator(
            knownKeys: loadKnownKeys(host: server.host, port: server.port, url: knownHostsURL)
        )

        let client = try await SSHClient.connect(
            host: server.host, port: server.port,
            authenticationMethod: auth, hostKeyValidator: .custom(validator), reconnect: .never
        )
        let sftp = try await client.openSFTP()
        let dir = await resolveDir(remoteDir, sftp: sftp)
        await ensureDir(dir, sftp: sftp)

        for (index, file) in files.enumerated() {
            try await uploadOne(
                file, into: dir, mode: mode, sftp: sftp,
                index: index, total: files.count, onProgress: onProgress
            )
        }
        try? await sftp.close()
        try? await client.close()
    }

    // MARK: Auth

    private func makeAuth(user: String, keyText: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let type: SSHKeyType
        do { type = try SSHKeyDetection.detectPrivateKeyType(from: keyText) }
        catch { throw ShareUploadError.keyParse("\(error)") }

        switch type {
        case .ed25519:
            do {
                let key = try Curve25519.Signing.PrivateKey(
                    sshEd25519: keyText, decryptionKey: passphrase?.data(using: .utf8)
                )
                return .ed25519(username: user, privateKey: key)
            } catch {
                if passphrase == nil { throw ShareUploadError.passphraseRequired }
                throw ShareUploadError.keyParse("\(error)")
            }
        case .rsa:
            do {
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyText)
                return .rsa(username: user, privateKey: key)
            } catch { throw ShareUploadError.keyParse("\(error)") }
        default:
            throw ShareUploadError.unsupportedKey(type.description)
        }
    }

    private func loadKnownKeys(host: String, port: Int, url: URL?) -> Set<NIOSSHPublicKey> {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let tokens: Set<String> = port == 22 ? [host] : ["[\(host)]:\(port)"]
        var keys: Set<NIOSSHPublicKey> = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|") else { continue }
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count >= 3 else { continue }
            guard fields[0].split(separator: ",").map(String.init).contains(where: { tokens.contains($0) }) else { continue }
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: fields[1] + " " + fields[2]) {
                keys.insert(key)
            }
        }
        return keys
    }

    // MARK: Upload

    private func uploadOne(
        _ fileURL: URL, into dir: String, mode: TransferMode, sftp: SFTPClient,
        index: Int, total: Int, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws {
        let name = fileURL.lastPathComponent
        let remotePath = dir == "." || dir.isEmpty ? name : "\(dir)/\(name)"
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        if mode == .sync,
           let remote = try? await sftp.getAttributes(at: remotePath),
           remote.size == size,
           let remoteMtime = remote.accessModificationTime?.modificationTime,
           remoteMtime >= mtime {
            onProgress(UploadProgress(index: index, total: total, fileName: name, fraction: 1, bytesPerSecond: 0))
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])

        let start = Date()
        let meter = ProgressBox()
        func emit() {
            let done = meter.value
            let elapsed = Date().timeIntervalSince(start)
            let speed = elapsed > 0 ? Double(done) / elapsed : 0
            let frac = size == 0 ? 1 : min(1, Double(done) / Double(size))
            onProgress(UploadProgress(index: index, total: total, fileName: name, fraction: frac, bytesPerSecond: speed))
        }
        emit()

        try await withThrowingTaskGroup(of: Int.self) { group in
            var inFlight = 0
            var offset: UInt64 = 0
            while true {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                let writeOffset = offset
                offset += UInt64(chunk.count)
                if inFlight >= maxInFlight, let n = try await group.next() {
                    inFlight -= 1; meter.add(n); emit()
                }
                group.addTask {
                    var buffer = ByteBuffer()
                    buffer.writeBytes(chunk)
                    try await file.write(buffer, at: writeOffset)
                    return chunk.count
                }
                inFlight += 1
            }
            while let n = try await group.next() { meter.add(n); emit() }
        }
        try await file.close()
        emit()

        var setAttrs = SFTPFileAttributes()
        setAttrs.accessModificationTime = .init(accessTime: Date(), modificationTime: mtime)
        try? await sftp.setAttributes(at: remotePath, to: setAttrs)
    }

    // MARK: Remote path helpers

    private func resolveDir(_ dir: String, sftp: SFTPClient) async -> String {
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

    private func ensureDir(_ dir: String, sftp: SFTPClient) async {
        guard dir != ".", dir != "/" else { return }
        let isAbsolute = dir.hasPrefix("/")
        var path = isAbsolute ? "" : "."
        for component in dir.split(separator: "/").map(String.init) {
            path = path.isEmpty ? "/\(component)" : "\(path)/\(component)"
            try? await sftp.createDirectory(atPath: path)
        }
    }
}

/// Thread-safe byte counter for pipelined progress.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var total: UInt64 = 0
    func add(_ n: Int) { lock.lock(); total += UInt64(n); lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return total }
}
