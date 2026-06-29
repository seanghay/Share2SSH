import Foundation
import SwiftUI
import Combine

/// Observable façade over `SSHConfigManager` for the SwiftUI layer.
@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [SSHServer] = []
    @Published private(set) var hasAccess: Bool = false
    @Published var lastError: String?

    private let manager = SSHConfigManager()

    init() {
        hasAccess = SecureBookmarkStore.shared.restoreAccess() != nil
        if hasAccess { reload() }
    }

    /// Prompt for `~/.ssh` access (first run) and load on success.
    func grantAccess() {
        hasAccess = SecureBookmarkStore.shared.requestAccess() != nil
        if hasAccess { reload() }
    }

    func reload() {
        guard hasAccess else { return }
        do {
            servers = try manager.loadServers()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func server(withAlias alias: String) -> SSHServer? {
        servers.first { $0.alias == alias }
    }

    func save(_ server: SSHServer, originalAlias: String? = nil) {
        do {
            try manager.save(server, originalAlias: originalAlias)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ server: SSHServer) {
        do {
            try manager.delete(alias: server.alias)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
