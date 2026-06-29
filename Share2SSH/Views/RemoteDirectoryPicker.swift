import SwiftUI

/// Modal dialog for choosing a remote directory as the upload destination.
/// Reuses the server's existing browser session and shows folders only.
struct RemoteDirectoryPicker: View {
    @ObservedObject var model: RemoteBrowserModel
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var passphrase = ""
    @State private var rememberPassphrase = false

    private var folders: [RemoteEntry] {
        model.entries.filter(\.isDirectory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a folder on “\(model.server.alias)”").font(.headline)
                Spacer()
            }
            .padding()

            Divider()

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
                .disabled(!model.isConnected)

                Text(model.currentPath.isEmpty ? "…" : model.currentPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)

            Divider()
            content
            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Select This Folder") {
                    onSelect(model.currentPath)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isConnected || model.currentPath.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 560, height: 460)
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

    @ViewBuilder
    private var content: some View {
        if model.isLoading && !model.isConnected {
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.server.alias)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isConnected {
            VStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Not connected").font(.headline)
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty && !model.isLoading {
            ContentUnavailableView(
                "No subfolders",
                systemImage: "folder",
                description: Text("Select this folder, or create a new one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(folders) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(entry.name)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { Task { await model.open(entry) } }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
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

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
}
