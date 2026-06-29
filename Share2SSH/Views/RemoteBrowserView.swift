import SwiftUI
import AppKit

/// Remote SFTP file explorer presented as a sheet. Lets the user navigate the
/// server, create/delete folders, download files, and choose a directory as
/// the upload destination.
struct RemoteBrowserView: View {
    @EnvironmentObject private var queue: TransferQueue
    @StateObject private var model: RemoteBrowserModel
    @Environment(\.dismiss) private var dismiss

    let onChooseDirectory: (String) -> Void

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var passphrase = ""
    @State private var rememberPassphrase = false

    init(server: SSHServer, onChooseDirectory: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: RemoteBrowserModel(server: server))
        self.onChooseDirectory = onChooseDirectory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 500)
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
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
            .disabled(model.currentPath.isEmpty)

            Text(model.currentPath.isEmpty ? "…" : model.currentPath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView("Empty folder", systemImage: "folder")
                .frame(maxHeight: .infinity)
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
            Button("Close") { dismiss() }
            Button("Use This Folder for Uploads") {
                onChooseDirectory(model.currentPath)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.currentPath.isEmpty)
        }
        .padding(10)
    }

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Passphrase for “\(model.server.alias)”").font(.headline)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            Toggle("Remember in Keychain", isOn: $rememberPassphrase)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.needsPassphrase = false
                    dismiss()
                }
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
