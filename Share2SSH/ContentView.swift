import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var queue: TransferQueue

    @State private var selection: String?
    @State private var editing: ServerEditTarget?

    var body: some View {
        NavigationSplitView {
            ServerListView(
                selection: $selection,
                onAdd: { editing = .new },
                onEdit: { editing = .existing($0) }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .sheet(item: $editing) { target in
            ServerEditView(target: target)
                .environmentObject(servers)
        }
        .sheet(item: $queue.passphraseRequest) { request in
            PassphraseSheet(request: request)
                .environmentObject(queue)
        }
        .alert("Heads up", isPresented: infoBinding) {
            Button("OK", role: .cancel) { queue.infoMessage = nil }
        } message: {
            Text(queue.infoMessage ?? "")
        }
        .onChange(of: servers.servers.map(\.alias)) { _, aliases in
            if selection == nil { selection = aliases.first }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !servers.hasAccess {
            GrantAccessView()
        } else if let alias = selection, let server = servers.server(withAlias: alias) {
            ServerDetailView(server: server)
                .id(server.alias)
        } else {
            ContentUnavailableView(
                "Select a server",
                systemImage: "server.rack",
                description: Text("Choose a server on the left, or add one to get started.")
            )
        }
    }

    private var infoBinding: Binding<Bool> {
        Binding(
            get: { queue.infoMessage != nil },
            set: { if !$0 { queue.infoMessage = nil } }
        )
    }
}

/// Detail pane: drop zone for one server plus the live transfer list.
struct ServerDetailView: View {
    let server: SSHServer

    @State private var mode: TransferMode
    @State private var remoteDir: String
    @State private var showBrowser = false

    init(server: SSHServer) {
        self.server = server
        _mode = State(initialValue: server.defaultMode)
        _remoteDir = State(initialValue: server.defaultRemoteDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.alias).font(.title2).bold()
                    Text(server.displaySummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showBrowser = true
                } label: {
                    Label("Browse Files", systemImage: "externaldrive.connected.to.line.below")
                }
            }
            .padding()

            DropZoneView(server: server, mode: $mode, remoteDir: $remoteDir)
                .padding(.horizontal)

            Divider().padding(.top)

            TransferListView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showBrowser) {
            RemoteBrowserView(server: server) { chosen in
                remoteDir = chosen
            }
        }
    }
}

/// Shown until the user grants access to ~/.ssh.
struct GrantAccessView: View {
    @EnvironmentObject private var servers: ServerStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Grant access to ~/.ssh")
                .font(.title2).bold()
            Text("Share2SSH reads and edits your SSH config, keys, and known_hosts. Because the app is sandboxed, macOS needs you to grant access once.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Grant Access…") { servers.grantAccess() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
