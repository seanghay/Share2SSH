import Foundation
import Citadel
import Crypto

enum KeyLoadError: LocalizedError {
    case fileNotFound
    case unreadable(String)
    case unsupportedType(String)
    case passphraseRequired
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "No SSH private key was found. Set an IdentityFile for this server or create ~/.ssh/id_ed25519."
        case .unreadable(let detail):
            return "Couldn't read the private key: \(detail)"
        case .unsupportedType(let type):
            return "Unsupported key type \(type). Share2SSH currently supports ed25519 and RSA keys."
        case .passphraseRequired:
            return "This private key is passphrase-protected."
        case .parseFailed(let detail):
            return "Couldn't parse the private key: \(detail)"
        }
    }
}

/// Loads an OpenSSH private key from disk and turns it into a Citadel
/// `SSHAuthenticationMethod`. Pure / off-main: callers pass the resolved
/// `~/.ssh` directory URL so key reads stay inside the granted security scope.
nonisolated enum SSHKeyLoader {
    static func authenticationMethod(
        for server: SSHServer,
        passphrase: String?,
        sshDirectoryURL: URL?
    ) throws -> SSHAuthenticationMethod {
        let keyURL = try resolveIdentityFile(server, sshDirectoryURL: sshDirectoryURL)
        let keyString: String
        do {
            keyString = try String(contentsOf: keyURL, encoding: .utf8)
        } catch {
            throw KeyLoadError.unreadable(error.localizedDescription)
        }

        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
        } catch {
            throw KeyLoadError.parseFailed(error.localizedDescription)
        }

        switch type {
        case .ed25519:
            do {
                let key = try Curve25519.Signing.PrivateKey(
                    sshEd25519: keyString,
                    decryptionKey: passphrase?.data(using: .utf8)
                )
                return .ed25519(username: server.user, privateKey: key)
            } catch {
                if passphrase == nil {
                    throw KeyLoadError.passphraseRequired
                }
                throw KeyLoadError.parseFailed(error.localizedDescription)
            }
        case .rsa:
            do {
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyString)
                return .rsa(username: server.user, privateKey: key)
            } catch {
                throw KeyLoadError.parseFailed(error.localizedDescription)
            }
        default:
            throw KeyLoadError.unsupportedType(type.description)
        }
    }

    /// Raw OpenSSH private key text for a server's identity file, if readable.
    /// Used to hand the key to the Share Extension via the App Group.
    static func rawKeyText(for server: SSHServer, sshDirectoryURL: URL?) -> String? {
        guard let url = try? resolveIdentityFile(server, sshDirectoryURL: sshDirectoryURL) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func resolveIdentityFile(
        _ server: SSHServer,
        sshDirectoryURL: URL?
    ) throws -> URL {
        let candidates: [String]
        if let identity = server.identityFile, !identity.isEmpty {
            candidates = [identity]
        } else {
            candidates = ["~/.ssh/id_ed25519", "~/.ssh/id_rsa", "~/.ssh/id_ecdsa"]
        }
        for candidate in candidates {
            let url = expand(candidate, sshDirectoryURL: sshDirectoryURL)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw KeyLoadError.fileNotFound
    }

    /// Expand a path, preferring the granted `~/.ssh` scope so reads stay
    /// inside the security-scoped bookmark.
    private static func expand(_ path: String, sshDirectoryURL: URL?) -> URL {
        if path.hasPrefix("~/.ssh/"), let sshDir = sshDirectoryURL {
            let tail = String(path.dropFirst("~/.ssh/".count))
            return sshDir.appendingPathComponent(tail)
        }
        if path.hasPrefix("~/") {
            return realHomeDirectory().appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    /// The user's real home directory, independent of the sandbox container.
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
