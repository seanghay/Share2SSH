import Foundation

/// One entry in a remote directory listing.
struct RemoteEntry: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: UInt64?
    var modified: Date?

    var id: String { path }

    var displaySize: String? {
        guard let size, !isDirectory else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
