import Foundation
import SwiftUI
import Combine

/// Owns one persistent `RemoteBrowserModel` per server so connections survive
/// switching between servers/tabs, and publishes which servers are connected
/// (for the green dot in the sidebar).
@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var connected: Set<String> = []

    private var models: [String: RemoteBrowserModel] = [:]

    func model(for server: SSHServer) -> RemoteBrowserModel {
        if let existing = models[server.alias] {
            existing.updateServer(server)
            return existing
        }
        let model = RemoteBrowserModel(server: server)
        model.onConnectionChange = { [weak self] alias, isConnected in
            guard let self else { return }
            if isConnected { self.connected.insert(alias) } else { self.connected.remove(alias) }
        }
        models[server.alias] = model
        return model
    }

    func isConnected(_ alias: String) -> Bool {
        connected.contains(alias)
    }

    func disconnect(_ alias: String) {
        guard let model = models[alias] else { return }
        Task { await model.disconnect() }
    }

    /// Drop a server entirely (e.g. it was deleted), closing any connection.
    func forget(_ alias: String) {
        if let model = models[alias] {
            Task { await model.stop() }
        }
        models[alias] = nil
        connected.remove(alias)
    }
}
