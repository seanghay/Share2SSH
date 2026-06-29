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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.items) { item in
                    TransferRow(item: item) { queue.cancel(item) }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).font(.body)
                Text("→ \(item.serverAlias):\(item.remoteDir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .transferring(let fraction, let sent, let total, let speed) = item.status {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    HStack(spacing: 8) {
                        Text(progressDetail(sent: sent, total: total))
                        if let speedText = speedText(speed) { Text("· \(speedText)") }
                        if let eta = etaText(sent: sent, total: total, speed: speed) {
                            Text("· \(eta)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            if item.status.isCancellable {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
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
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .connecting: return "Connecting…"
        case .transferring(let fraction, _, _, _): return "\(Int(fraction * 100))%"
        case .skipped: return "Up to date"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    // MARK: Formatting

    private func progressDetail(sent: UInt64, total: UInt64) -> String {
        let sentStr = ByteCountFormatter.string(fromByteCount: Int64(sent), countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "\(sentStr) / \(totalStr)"
    }

    private func speedText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0 else { return nil }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(rate)/s"
    }

    private func etaText(sent: UInt64, total: UInt64, speed: Double) -> String? {
        guard speed > 0, total > sent else { return nil }
        let remaining = Double(total - sent) / speed
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        guard let text = formatter.string(from: remaining) else { return nil }
        return "\(text) left"
    }
}
