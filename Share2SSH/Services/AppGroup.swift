import Foundation

/// Shared container coordinates between the main app and the Share Extension.
///
/// - The main app writes a sanitized `servers.json` here so the (sandboxed)
///   extension can show a server picker without touching `~/.ssh`.
/// - The extension copies dropped files into `Inbox/<jobId>/` and writes a
///   `job.json` there, then opens the main app via the `share2ssh://` URL.
enum AppGroup {
    static let identifier = "group.com.seanghay.Share2SSH"
    static let urlScheme = "share2ssh"

    static let serversCacheFileName = "servers.json"
    static let jobFileName = "job.json"

    /// Root of the shared App Group container. `nil` if the entitlement is
    /// missing (e.g. running unsigned) — callers must handle that.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var inboxRootURL: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func inboxURL(for jobID: String) -> URL? {
        inboxRootURL?.appendingPathComponent(jobID, isDirectory: true)
    }

    static var serversCacheURL: URL? {
        containerURL?.appendingPathComponent(serversCacheFileName)
    }

    // MARK: - Server cache (written by main app, read by extension)

    /// Sanitized server info exposed to the extension. Deliberately excludes
    /// anything secret — just enough to render a picker and build a job.
    struct ServerCacheEntry: Codable, Identifiable, Hashable, Sendable {
        var alias: String
        var summary: String
        var defaultRemoteDir: String
        var defaultMode: TransferMode
        var id: String { alias }
    }

    static func writeServerCache(_ servers: [SSHServer]) {
        guard let url = serversCacheURL else { return }
        let entries = servers.map {
            ServerCacheEntry(
                alias: $0.alias,
                summary: $0.displaySummary,
                defaultRemoteDir: $0.defaultRemoteDir,
                defaultMode: $0.defaultMode
            )
        }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Share2SSH: failed to write server cache: \(error)")
        }
    }

    static func readServerCache() -> [ServerCacheEntry] {
        guard let url = serversCacheURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ServerCacheEntry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - URL hand-off

    static func transferURL(jobID: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "transfer"
        components.queryItems = [URLQueryItem(name: "job", value: jobID)]
        return components.url
    }

    static func jobID(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "transfer" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "job" })?.value
    }
}
