import SwiftUI
import AppKit

enum ServerEditTarget: Identifiable {
    case new
    case existing(SSHServer)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let server): return server.alias
        }
    }
}

/// Add / edit form for a server. Writes through to ~/.ssh/config on save.
struct ServerEditView: View {
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    let target: ServerEditTarget

    @State private var alias = ""
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var port = "22"
    @State private var identityFile = ""
    @State private var remoteDir = "~/"
    @State private var mode: TransferMode = .copy

    private var originalAlias: String? {
        if case .existing(let server) = target { return server.alias }
        return nil
    }

    private var isValid: Bool {
        !alias.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(originalAlias == nil ? "Add Server" : "Edit Server")
                .font(.title2).bold()
                .padding()

            Form {
                Section("Connection") {
                    TextField("Alias", text: $alias, prompt: Text("web"))
                    TextField("Host", text: $host, prompt: Text("example.com"))
                    TextField("User", text: $user)
                    TextField("Port", text: $port)
                }
                Section("Authentication") {
                    HStack {
                        TextField("Identity file", text: $identityFile, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…", action: chooseIdentityFile)
                    }
                }
                Section("Defaults") {
                    TextField("Remote directory", text: $remoteDir, prompt: Text("~/uploads"))
                    Picker("Transfer mode", selection: $mode) {
                        ForEach(TransferMode.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 460, height: 480)
        .onAppear(perform: populate)
    }

    private func populate() {
        guard case .existing(let server) = target else { return }
        alias = server.alias
        host = server.resolvedHost
        user = server.user
        port = String(server.port)
        identityFile = server.identityFile ?? ""
        remoteDir = server.defaultRemoteDir
        mode = server.defaultMode
    }

    private func save() {
        let server = SSHServer(
            alias: alias.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            identityFile: identityFile.isEmpty ? nil : identityFile,
            defaultRemoteDir: remoteDir.isEmpty ? "~/" : remoteDir,
            defaultMode: mode
        )
        servers.save(server, originalAlias: originalAlias)
        dismiss()
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SecureBookmarkStore.shared.defaultSSHDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Prefer the portable ~/.ssh/<name> form when the key lives there.
        let sshDir = SecureBookmarkStore.shared.defaultSSHDirectory.path
        if url.path.hasPrefix(sshDir + "/") {
            identityFile = "~/.ssh/" + String(url.path.dropFirst(sshDir.count + 1))
        } else {
            identityFile = url.path
        }
    }
}

/// Prompt for a private key passphrase when a transfer needs one.
struct PassphraseSheet: View {
    @EnvironmentObject private var queue: TransferQueue
    @Environment(\.dismiss) private var dismiss

    let request: PassphraseRequest
    @State private var passphrase = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Passphrase for “\(request.serverAlias)”")
                .font(.headline)
            Text("This server's private key is passphrase-protected.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    queue.passphraseRequest = nil
                    dismiss()
                }
                Button("Unlock") {
                    queue.submitPassphrase(passphrase, remember: remember, for: request.serverAlias)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
