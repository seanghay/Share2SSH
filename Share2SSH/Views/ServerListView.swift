import SwiftUI

/// Sidebar list of configured servers with add / edit / delete.
struct ServerListView: View {
    @EnvironmentObject private var servers: ServerStore
    @Binding var selection: String?
    let onAdd: () -> Void
    let onEdit: (SSHServer) -> Void

    @State private var pendingDelete: SSHServer?

    var body: some View {
        List(selection: $selection) {
            Section("Servers") {
                ForEach(servers.servers) { server in
                    serverRow(server)
                        .tag(server.alias)
                        .contextMenu {
                            Button("Edit…") { onEdit(server) }
                            Button("Delete…", role: .destructive) { pendingDelete = server }
                        }
                }
            }
        }
        .overlay {
            if servers.hasAccess && servers.servers.isEmpty {
                ContentUnavailableView(
                    "No servers yet",
                    systemImage: "plus.circle",
                    description: Text("Add a server to start sending files.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: onAdd) { Label("Add Server", systemImage: "plus") }
                    .disabled(!servers.hasAccess)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.alias ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let server = pendingDelete { servers.delete(server) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the Host block from ~/.ssh/config.")
        }
    }

    private func serverRow(_ server: SSHServer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.alias).font(.body)
            Text(server.displaySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}
