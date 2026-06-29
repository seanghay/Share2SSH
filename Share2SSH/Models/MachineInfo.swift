import Foundation

/// A snapshot of basic remote machine details, gathered over SSH on connect.
struct MachineInfo: Equatable, Sendable {
    var hostname: String?
    var os: String?
    var kernel: String?
    var arch: String?
    var cpu: String?
    var memory: String?
    var uptime: String?

    /// Ordered (label, value) rows for display, skipping anything we couldn't read.
    var rows: [(String, String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { out.append((label, value)) }
        }
        add("Host", hostname)
        add("OS", os)
        add("Kernel", kernel)
        add("Arch", arch)
        add("CPU", cpu.map { "\($0) cores" })
        add("Memory", memory)
        add("Uptime", uptime)
        return out
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Parse the `key=value` lines emitted by the info command.
    static func parse(_ text: String) -> MachineInfo {
        var info = MachineInfo()
        for line in text.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "host": info.hostname = value
            case "os": info.os = value
            case "kernel": info.kernel = value
            case "arch": info.arch = value
            case "cpu": info.cpu = value
            case "mem": info.memory = value
            case "uptime": info.uptime = value
            default: break
            }
        }
        return info
    }
}
