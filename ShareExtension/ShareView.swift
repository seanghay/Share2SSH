import SwiftUI
import Combine

@MainActor
final class ShareModel: ObservableObject {
    @Published var servers: [ServerCacheEntry]
    @Published var selectedAlias: String?
    @Published var mode: TransferMode = .copy
    @Published var remoteDir: String = "~/"

    let stagedFiles: [URL]
    var fileCount: Int { stagedFiles.count }

    enum Phase: Equatable { case configuring, uploading, done, failed }
    @Published var phase: Phase = .configuring
    @Published var progress: UploadProgress?
    @Published var needsPassphrase = false
    @Published var errorMessage: String?

    /// Set by the view controller to finish/cancel the extension request.
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let uploader = ShareUploader()
    private var passphrase: String?

    init(servers: [ServerCacheEntry], stagedFiles: [URL]) {
        self.servers = servers
        self.stagedFiles = stagedFiles
        if let first = servers.first {
            selectedAlias = first.alias
            mode = first.defaultMode
            remoteDir = first.defaultRemoteDir
        }
    }

    var selectedServer: ServerCacheEntry? { servers.first { $0.alias == selectedAlias } }

    func selectServer(_ alias: String) {
        selectedAlias = alias
        if let server = selectedServer {
            mode = server.defaultMode
            remoteDir = server.defaultRemoteDir
        }
    }

    func startUpload() {
        guard selectedServer != nil else { return }
        phase = .uploading
        Task { await runUpload() }
    }

    func submitPassphrase(_ value: String) {
        passphrase = value
        needsPassphrase = false
        phase = .uploading
        Task { await runUpload() }
    }

    func cancel() { onCancel?() }
    func finish() { cleanupStaging(); onFinish?() }

    private func runUpload() async {
        guard let server = selectedServer else { return }
        do {
            try await uploader.upload(
                files: stagedFiles, server: server, remoteDir: remoteDir, mode: mode,
                passphrase: passphrase, knownHostsURL: AppGroup.knownHostsURL
            ) { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            }
            phase = .done
        } catch ShareUploadError.passphraseRequired {
            phase = .configuring
            needsPassphrase = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            phase = .failed
        }
    }

    private func cleanupStaging() {
        if let dir = stagedFiles.first?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send to server").font(.headline)
            Text("^[\(model.fileCount) file](inflect: true) selected")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch model.phase {
            case .configuring: configuring
            case .uploading: uploading
            case .done: done
            case .failed: failed
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .sheet(isPresented: $model.needsPassphrase) { passphraseSheet }
    }

    // MARK: Phases

    @ViewBuilder
    private var configuring: some View {
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
                        Text(verbatim: "\(server.alias)  —  \(server.summary)").tag(server.alias)
                    }
                }
                if let server = model.selectedServer {
                    LabeledContent("Address") { Text(server.summary).textSelection(.enabled) }
                }
                Picker("Mode", selection: $model.mode) {
                    ForEach(TransferMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Remote directory", text: $model.remoteDir, prompt: Text("~/uploads"))
            }
            .formStyle(.grouped)

            buttonRow {
                Button("Cancel", role: .cancel) { model.cancel() }
                Button("Upload") { model.startUpload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedServer == nil)
            }
        }
    }

    private var uploading: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: model.progress?.fraction ?? 0) {
                Text(progressTitle)
            }
            .frame(maxWidth: 360)
            Text(progressDetail).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Uploaded ^[\(model.fileCount) file](inflect: true)").font(.headline)
            Spacer()
            buttonRow {
                Button("Done") { model.finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var failed: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(.red)
            Text("Upload failed").font(.headline)
            Text(model.errorMessage ?? "")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            buttonRow {
                Button("Close", role: .cancel) { model.cancel() }
                Button("Retry") { model.startUpload() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Passphrase for “\(model.selectedServer?.alias ?? "")”").font(.headline)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.needsPassphrase = false
                    passphrase = ""
                }
                Button("Unlock") {
                    let value = passphrase
                    passphrase = ""
                    model.submitPassphrase(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: Helpers

    private func buttonRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(); content() }
    }

    private var progressTitle: String {
        guard let p = model.progress else { return "Connecting…" }
        let base = p.total > 1 ? "Uploading \(p.index + 1) of \(p.total): " : "Uploading "
        return base + p.fileName
    }

    private var progressDetail: String {
        guard let p = model.progress, p.bytesPerSecond > 0 else { return "" }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file)
        return "\(Int(p.fraction * 100))% · \(rate)/s"
    }
}
