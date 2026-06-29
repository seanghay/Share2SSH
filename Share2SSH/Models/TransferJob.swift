import Foundation

/// A request to upload one or more files to a server.
///
/// This is the hand-off contract written to the App Group inbox by the Share
/// Extension and consumed by the main app. It only references files by name
/// inside the job's inbox folder — the extension copies the bytes there because
/// security-scoped URLs don't cross the process boundary.
struct TransferJob: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var serverAlias: String
    var mode: TransferMode
    var remoteDir: String
    /// File names located inside `AppGroup.inboxURL(for: id)`.
    var fileNames: [String]

    init(
        id: String,
        serverAlias: String,
        mode: TransferMode,
        remoteDir: String,
        fileNames: [String]
    ) {
        self.id = id
        self.serverAlias = serverAlias
        self.mode = mode
        self.remoteDir = remoteDir
        self.fileNames = fileNames
    }
}

/// State of a single file transfer in the queue.
enum TransferStatus: Equatable, Sendable {
    case queued
    case connecting
    case transferring(fractionCompleted: Double, bytesSent: UInt64, totalBytes: UInt64, bytesPerSecond: Double)
    case skipped
    case completed
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .skipped, .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    /// Whether the transfer can still be cancelled.
    var isCancellable: Bool {
        switch self {
        case .queued, .connecting, .transferring: return true
        default: return false
        }
    }
}
