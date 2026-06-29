import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop target (plus a file picker) that enqueues uploads for one server.
struct DropZoneView: View {
    @EnvironmentObject private var queue: TransferQueue
    @EnvironmentObject private var browsers: BrowserStore
    let server: SSHServer
    @Binding var mode: TransferMode
    @Binding var remoteDir: String

    @State private var isTargeted = false
    @State private var showDirectoryPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Mode", selection: $mode) {
                    ForEach(TransferMode.allCases) { mode in
                        Label(mode.shortTitle, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Label(mode.subtitle, systemImage: mode.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .id(mode)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                TextField("Remote directory", text: $remoteDir, prompt: Text("~/uploads"))
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { showDirectoryPicker = true }
                    .help("Browse the server to pick a folder")
            }

            dropTarget
        }
        .animation(.easeInOut(duration: 0.15), value: mode)
        .sheet(isPresented: $showDirectoryPicker) {
            RemoteDirectoryPicker(model: browsers.model(for: server)) { chosen in
                remoteDir = chosen
            }
        }
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .frame(height: 140)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    Text("Drop files here to send to **\(server.alias)**")
                    Button("Choose Files…", action: chooseFiles)
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        enqueue(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accumulator = URLAccumulator()
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { accumulator.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = accumulator.all()
            if !urls.isEmpty { enqueue(urls) }
        }
        return true
    }

    private func enqueue(_ urls: [URL]) {
        queue.enqueue(files: urls, server: server, mode: mode, remoteDir: remoteDir)
    }
}

/// Thread-safe collector for drop callbacks that fire on arbitrary queues.
private final class URLAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock(); urls.append(url); lock.unlock()
    }

    func all() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}
