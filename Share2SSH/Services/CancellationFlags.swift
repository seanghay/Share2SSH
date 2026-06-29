import Foundation

/// Thread-safe set of cancelled transfer item IDs, shared between the
/// MainActor queue (which sets them) and the off-main transfer engine (which
/// polls them).
final class CancellationFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func cancel(_ id: String) {
        lock.lock(); ids.insert(id); lock.unlock()
    }

    func isCancelled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    func clear(_ id: String) {
        lock.lock(); ids.remove(id); lock.unlock()
    }
}
