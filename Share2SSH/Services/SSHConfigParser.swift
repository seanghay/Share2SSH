import Foundation

/// A single `Host` block in `~/.ssh/config`, kept as raw lines so we can
/// round-trip the file without destroying comments, formatting, or options we
/// don't model.
struct SSHHostBlock: Hashable {
    /// Patterns on the `Host` line, e.g. `["web", "web-*"]`.
    var aliases: [String]
    /// Every raw line of the block, starting with the `Host ...` line.
    var rawLines: [String]

    /// A block is an editable "server" only if it names exactly one concrete
    /// (non-wildcard) host.
    var isConcreteServer: Bool {
        aliases.count == 1 && !SSHConfigFile.isPattern(aliases[0])
    }
}

/// In-memory representation of an `~/.ssh/config` file that supports lossless
/// round-tripping plus surgical add/edit/delete of the `Host` blocks we manage.
struct SSHConfigFile {
    /// Raw lines before the first `Host`/`Match` (global options, comments).
    var preamble: [String]
    var blocks: [SSHHostBlock]

    private static let managedKeys: Set<String> = ["hostname", "user", "port", "identityfile"]

    // MARK: Parsing

    static func parse(_ text: String) -> SSHConfigFile {
        // Preserve line endings as `\n`; keep content verbatim otherwise.
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var preamble: [String] = []
        var blocks: [SSHHostBlock] = []
        var current: SSHHostBlock?

        func flush() {
            if let block = current { blocks.append(block) }
            current = nil
        }

        for line in lines {
            if let kw = keyword(of: line), kw == "host" {
                flush()
                current = SSHHostBlock(aliases: values(of: line), rawLines: [line])
            } else if current != nil {
                current?.rawLines.append(line)
            } else {
                preamble.append(line)
            }
        }
        flush()
        return SSHConfigFile(preamble: preamble, blocks: blocks)
    }

    func serialize() -> String {
        var out = preamble
        for block in blocks { out.append(contentsOf: block.rawLines) }
        return out.joined(separator: "\n")
    }

    // MARK: Servers

    /// Concrete, editable servers parsed from the file (metadata defaulted —
    /// the caller merges in the sidecar values).
    var servers: [SSHServer] {
        blocks.compactMap { block in
            guard block.isConcreteServer else { return nil }
            let alias = block.aliases[0]
            return SSHServer(
                alias: alias,
                host: firstValue(in: block, key: "hostname") ?? alias,
                user: firstValue(in: block, key: "user") ?? NSUserName(),
                port: Int(firstValue(in: block, key: "port") ?? "") ?? 22,
                identityFile: firstValue(in: block, key: "identityfile")
            )
        }
    }

    // MARK: Mutation

    mutating func upsert(_ server: SSHServer) {
        if let index = blocks.firstIndex(where: {
            $0.isConcreteServer && $0.aliases[0] == server.alias
        }) {
            blocks[index] = rewrite(block: blocks[index], with: server)
        } else {
            blocks.append(newBlock(for: server))
        }
    }

    mutating func remove(alias: String) {
        blocks.removeAll { $0.isConcreteServer && $0.aliases[0] == alias }
    }

    /// Rewrite only the managed keys of an existing block, preserving any
    /// custom options and indentation style we find.
    private func rewrite(block: SSHHostBlock, with server: SSHServer) -> SSHHostBlock {
        let indent = detectIndent(in: block) ?? "    "
        var result: [String] = ["Host \(server.alias)"]

        // Keep non-managed body lines (custom options, comments, blanks).
        for line in block.rawLines.dropFirst() {
            if let kw = SSHConfigFile.keyword(of: line),
               SSHConfigFile.managedKeys.contains(kw) {
                continue
            }
            result.append(line)
        }
        // Insert canonical managed keys right after the Host line.
        let managed = managedLines(for: server, indent: indent)
        result.insert(contentsOf: managed, at: 1)
        return SSHHostBlock(aliases: [server.alias], rawLines: result)
    }

    private func newBlock(for server: SSHServer) -> SSHHostBlock {
        var lines = [""] // blank separator before the new block
        lines.append("Host \(server.alias)")
        lines.append(contentsOf: managedLines(for: server, indent: "    "))
        return SSHHostBlock(aliases: [server.alias], rawLines: lines)
    }

    private func managedLines(for server: SSHServer, indent: String) -> [String] {
        var lines = [
            "\(indent)HostName \(server.resolvedHost)",
            "\(indent)User \(server.user)",
            "\(indent)Port \(server.port)",
        ]
        if let identity = server.identityFile, !identity.isEmpty {
            lines.append("\(indent)IdentityFile \(identity)")
        }
        return lines
    }

    // MARK: Line helpers

    static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }

    /// Lowercased keyword of a config line, or `nil` for blank/comment lines.
    static func keyword(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).first
        return token.map { $0.lowercased() }
    }

    /// All whitespace-separated values after the keyword on a line.
    private static func values(of line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
        if !parts.isEmpty { parts.removeFirst() } // drop keyword
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    private func firstValue(in block: SSHHostBlock, key: String) -> String? {
        for line in block.rawLines.dropFirst() where SSHConfigFile.keyword(of: line) == key {
            let v = SSHConfigFile.values(of: line)
            if let first = v.first, !first.isEmpty { return first }
        }
        return nil
    }

    private func detectIndent(in block: SSHHostBlock) -> String? {
        for line in block.rawLines.dropFirst() {
            guard SSHConfigFile.keyword(of: line) != nil else { continue }
            let whitespace = line.prefix { $0 == " " || $0 == "\t" }
            if !whitespace.isEmpty { return String(whitespace) }
        }
        return nil
    }
}
