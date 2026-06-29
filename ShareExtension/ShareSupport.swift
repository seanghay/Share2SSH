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
    var defaultRemoteDir: String
    var defaultMode: TransferMode
    var id: String { alias }
}

struct TransferJob: Codable, Identifiable, Sendable {
    var id: String
    var serverAlias: String
    var mode: TransferMode
    var remoteDir: String
    var fileNames: [String]
}

enum AppGroup {
    static let identifier = "group.com.seanghay.Share2SSH"
    static let hostBundleID = "com.seanghay.Share2SSH"
    static let serversCacheFileName = "servers.json"
    static let jobFileName = "job.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func inboxURL(for jobID: String) -> URL? {
        containerURL?
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
    }

    static func readServerCache() -> [ServerCacheEntry] {
        guard let url = containerURL?.appendingPathComponent(serversCacheFileName),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ServerCacheEntry].self, from: data)
        else { return [] }
        return entries
    }
}
