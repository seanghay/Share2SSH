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

/// Detail pane: a "Send" tab (drop zone + transfers) and a "Files" tab (remote
/// explorer) for the selected server.
struct ServerDetailView: View {
    enum DetailTab: Hashable { case send, files }

    let server: SSHServer
    @EnvironmentObject private var browsers: BrowserStore

    @State private var mode: TransferMode
    @State private var remoteDir: String
    @State private var selectedTab: DetailTab = .send

    init(server: SSHServer) {
        self.server = server
        _mode = State(initialValue: server.defaultMode)
        _remoteDir = State(initialValue: server.defaultRemoteDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ConnectionDot(connected: browsers.isConnected(server.alias))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.alias).font(.title2).bold()
                    Text(server.displaySummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            TabView(selection: $selectedTab) {
                sendTab
                    .tabItem { Label("Send", systemImage: "arrow.up.doc") }
                    .tag(DetailTab.send)

                RemoteBrowserView(
                    model: browsers.model(for: server),
                    remoteDir: $remoteDir,
                    onUseFolder: { selectedTab = .send }
                )
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(DetailTab.files)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sendTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            DropZoneView(server: server, mode: $mode, remoteDir: $remoteDir)
                .padding(.top)
            Divider().padding(.top)
            TransferListView()
        }
    }
}

/// Small filled circle indicating connection state.
struct ConnectionDot: View {
    let connected: Bool
    var body: some View {
        Circle()
            .fill(connected ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 9, height: 9)
            .help(connected ? "Connected" : "Not connected")
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
