import SwiftUI
import AppKit

/// Remote SFTP file explorer, shown as the "Files" tab for a server. Navigate
/// the server, create/delete folders, upload, download, disconnect, and pick a
/// directory as the upload destination.
struct RemoteBrowserView: View {
    @EnvironmentObject private var queue: TransferQueue
    @ObservedObject var model: RemoteBrowserModel
    @Binding var remoteDir: String
    let onUseFolder: () -> Void

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var passphrase = ""
    @State private var rememberPassphrase = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let dl = model.download {
                Divider()
                downloadBar(dl)
            }
            Divider()
            footer
        }
        .task { await model.start() }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeDirectory(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .sheet(isPresented: $model.needsPassphrase) { passphraseSheet }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: { Task { await model.goUp() } }) {
                Image(systemName: "arrow.up")
            }
            .help("Go up")

            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button(action: { showNewFolder = true }) {
                Image(systemName: "folder.badge.plus")
            }
            .help("New folder")

            Button(action: uploadFiles) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Upload files here")
            .disabled(!model.isConnected || model.currentPath.isEmpty)

            Text(model.currentPath.isEmpty ? "…" : model.currentPath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isLoading { ProgressView().controlSize(.small) }

            if model.isConnected {
                Button(role: .destructive) {
                    Task { await model.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .help("Disconnect from the server")
            }
        }
        .padding(10)
        .disabled(!model.isConnected && !isBusy)
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConnected && !isBusy {
            VStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Not connected").font(.headline)
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView("Empty folder", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.entries) { entry in
                RemoteRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if entry.isDirectory { Task { await model.open(entry) } }
                    }
                    .contextMenu {
                        if entry.isDirectory {
                            Button("Open") { Task { await model.open(entry) } }
                        } else {
                            Button("Download…") { download(entry) }
                        }
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(entry) }
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Use This Folder for Uploads") {
                remoteDir = model.currentPath
                onUseFolder()
            }
            .disabled(!model.isConnected || model.currentPath.isEmpty)
        }
        .padding(10)
    }

    private func downloadBar(_ dl: RemoteBrowserModel.DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                Text("Downloading \(dl.fileName)").font(.callout).lineLimit(1)
                Spacer()
                Text("\(Int(dl.fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                Button(action: { model.cancelDownload() }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
            }
            ProgressView(value: dl.fraction)
            HStack(spacing: 8) {
                Text(byteDetail(dl.received, dl.total))
                if dl.bytesPerSecond > 0 {
                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(dl.bytesPerSecond), countStyle: .file))/s")
                }
                if let eta = etaText(received: dl.received, total: dl.total, speed: dl.bytesPerSecond) {
                    Text("· \(eta)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func etaText(received: UInt64, total: UInt64, speed: Double) -> String? {
        guard speed > 0, total > received else { return nil }
        let remaining = Double(total - received) / speed
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        guard let text = formatter.string(from: remaining) else { return nil }
        return "\(text) left"
    }

    private func byteDetail(_ received: UInt64, _ total: UInt64) -> String {
        let r = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        guard total > 0 else { return r }
        let t = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "\(r) / \(t)"
    }

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Passphrase for “\(model.server.alias)”").font(.headline)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            Toggle("Remember in Keychain", isOn: $rememberPassphrase)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.needsPassphrase = false }
                Button("Unlock") {
                    let value = passphrase
                    passphrase = ""
                    Task { await model.submitPassphrase(value, remember: rememberPassphrase) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: Helpers

    private var isBusy: Bool { model.isLoading }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        queue.enqueue(files: panel.urls, server: model.server, mode: .copy, remoteDir: model.currentPath)
        model.statusMessage = "Uploading \(panel.urls.count) file(s) to this folder…"
    }

    private func download(_ entry: RemoteEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.download(entry, to: url) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
}

private struct RemoteRow: View {
    let entry: RemoteEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            Text(entry.name)
            Spacer()
            if let size = entry.displaySize {
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
