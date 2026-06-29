import SwiftUI
import Combine

@MainActor
final class ShareModel: ObservableObject {
    @Published var servers: [ServerCacheEntry]
    @Published var selectedAlias: String?
    @Published var mode: TransferMode = .copy
    @Published var remoteDir: String = "~/"
    let fileCount: Int

    init(servers: [ServerCacheEntry], fileCount: Int) {
        self.servers = servers
        self.fileCount = fileCount
        if let first = servers.first {
            selectedAlias = first.alias
            mode = first.defaultMode
            remoteDir = first.defaultRemoteDir
        }
    }

    var selectedServer: ServerCacheEntry? {
        servers.first { $0.alias == selectedAlias }
    }

    func selectServer(_ alias: String) {
        selectedAlias = alias
        if let server = selectedServer {
            mode = server.defaultMode
            remoteDir = server.defaultRemoteDir
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onSend: (ServerCacheEntry, TransferMode, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send to server")
                .font(.headline)
            Text("^[\(model.fileCount) file](inflect: true) selected")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.servers.isEmpty {
                ContentUnavailableView(
                    "No servers",
                    systemImage: "server.rack",
                    description: Text("Add a server in the Share2SSH app first.")
                )
                .frame(maxHeight: .infinity)
            } else {
                Form {
                    Picker("Server", selection: Binding(
                        get: { model.selectedAlias ?? "" },
                        set: { model.selectServer($0) }
                    )) {
                        ForEach(model.servers) { server in
                            Text(server.alias).tag(server.alias)
                        }
                    }
                    Picker("Mode", selection: $model.mode) {
                        ForEach(TransferMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Remote directory", text: $model.remoteDir, prompt: Text("~/uploads"))
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Send") {
                    if let server = model.selectedServer {
                        onSend(server, model.mode, model.remoteDir)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedServer == nil)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
    }
}
