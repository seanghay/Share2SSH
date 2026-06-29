import Foundation

// Self-contained copies of the small types the extension needs. They are
// JSON-compatible with the main app's `TransferMode`, `AppGroup.ServerCacheEntry`,
// and `TransferJob` so the two processes can exchange files through the App
// Group container. The extension deliberately does NOT link Citadel or touch
// ~/.ssh — it only stages files and writes a job descriptor.

enum TransferMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy
    case sync
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: return "Copy"
        case .sync: return "Sync (skip unchanged)"
        }
    }
}

struct ServerCacheEntry: Codable, Identifiable, Hashable, Sendable {
    var alias: String
    var summary: String
    var host: String
    var user: String
    var port: Int
    var defaultRemoteDir: String
    var defaultMode: TransferMode
    var privateKey: String?
    var id: String { alias }
}

enum AppGroup {
    static let identifier = "group.com.seanghay.Share2SSH"
    static let serversCacheFileName = "servers.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var knownHostsURL: URL? {
        containerURL?.appendingPathComponent("known_hosts")
    }

    static func stagingURL(for id: String) -> URL? {
        containerURL?
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    static func readServerCache() -> [ServerCacheEntry] {
        guard let url = containerURL?.appendingPathComponent(serversCacheFileName),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ServerCacheEntry].self, from: data)
        else { return [] }
        return entries
    }
}
