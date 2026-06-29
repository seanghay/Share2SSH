import SwiftUI

/// Live list of all transfers in the queue.
struct TransferListView: View {
    @EnvironmentObject private var queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if queue.items.contains(where: { $0.status.isTerminal }) {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.link)
                }
            }
            .padding([.horizontal, .top])

            if queue.items.isEmpty {
                ContentUnavailableView(
                    "No transfers",
                    systemImage: "tray",
                    description: Text("Dropped and shared files appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(queue.items) { item in
                    TransferRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).font(.body)
                Text("→ \(item.serverAlias):\(item.remoteDir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .transferring(let fraction) = item.status {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
                if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .connecting:
            ProgressView().controlSize(.small)
        case .transferring:
            Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .connecting: return "Connecting…"
        case .transferring(let fraction): return "\(Int(fraction * 100))%"
        case .skipped: return "Up to date"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
}
