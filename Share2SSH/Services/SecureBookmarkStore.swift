import Foundation
import AppKit

/// Grants and persists access to the user's `~/.ssh` directory.
///
/// `~/.ssh` lives outside the app sandbox container, so the app cannot read the
/// ssh config, keys, or known_hosts without an explicit, persisted
/// security-scoped bookmark. We obtain it once via an `NSOpenPanel` and resolve
/// it on every launch.
@MainActor
final class SecureBookmarkStore {
    static let shared = SecureBookmarkStore()

    private let defaultsKey = "sshDirectoryBookmark"
    /// The resolved, access-started URL for `~/.ssh`, if granted.
    private(set) var sshDirectoryURL: URL?

    private init() {}

    var hasAccess: Bool { sshDirectoryURL != nil }

    /// Default location we point the open panel at.
    var defaultSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Attempt to restore access from a previously stored bookmark.
    /// - Returns: the URL on success, `nil` if there is no bookmark or it is stale.
    @discardableResult
    func restoreAccess() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else { return nil }
            sshDirectoryURL = url
            if isStale { try? storeBookmark(for: url) }
            return url
        } catch {
            NSLog("Share2SSH: failed to resolve ~/.ssh bookmark: \(error)")
            return nil
        }
    }

    /// Present an open panel so the user can grant access to `~/.ssh`.
    /// - Returns: the granted URL, or `nil` if cancelled / failed.
    @discardableResult
    func requestAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Grant access to your SSH folder"
        panel.message = "Share2SSH needs access to ~/.ssh to read and edit your SSH config, keys, and known_hosts."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultSSHDirectory
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        do {
            try storeBookmark(for: url)
            sshDirectoryURL = url
            return url
        } catch {
            NSLog("Share2SSH: failed to bookmark ~/.ssh: \(error)")
            url.stopAccessingSecurityScopedResource()
            return nil
        }
    }

    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
