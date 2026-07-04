import Foundation

/// An SSH connection configuration stored in the workspace folder.
struct SSHConnection: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String           // friendly label, e.g. "dev-server"
    var host: String           // hostname or IP
    var user: String           // SSH username
    var port: Int              // default 22
    var remotePath: String     // remote working directory
    var keyPath: String        // path to SSH private key (empty = default)
    var configAlias: String    // SSH config Host alias (e.g. "dev-workbench"), used for connections with ProxyCommand
    var lastTestedAt: Date?
    var lastTestResult: Bool?

    init(
        name: String = "",
        host: String = "",
        user: String = "",
        port: Int = 22,
        remotePath: String = "~",
        keyPath: String = "",
        configAlias: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.remotePath = remotePath
        self.keyPath = keyPath
        self.configAlias = configAlias
    }

    var displayLabel: String {
        if !name.isEmpty { return name }
        return "\(user)@\(host):\(remotePath)"
    }

    var sshTarget: String {
        "\(user)@\(host)"
    }
}

/// Manages SSH connections stored as a JSON file in the workspace folder.
enum SSHConnectionManager {
    private static let emptyConnectionsFileMaximumByteCount = 4
    private static let defaultFileWriter: any SSHConnectionFileWriting = AtomicSSHConnectionFileWriter()

    static func connectionsFilePath(for workspacePath: String) -> String {
        WorkspaceFileLayout.sshConnectionsFile(for: workspacePath)
    }

    static func hasStoredConnections(workspacePath: String) -> Bool {
        guard !workspacePath.isEmpty else { return false }
        let broker = HostFileAccessBroker()
        let workspaceRoot = URL(fileURLWithPath: workspacePath, isDirectory: true)
        return connectionFilePaths(for: workspacePath).contains { path in
            let url = URL(fileURLWithPath: path)
            guard let fileSize = broker.fileSize(
                at: url,
                intent: .astraManagedStorage(root: workspaceRoot)
            ) else {
                return false
            }
            return fileSize > emptyConnectionsFileMaximumByteCount
        }
    }

    static func load(workspacePath: String) -> [SSHConnection] {
        migrateLegacyConnectionsIfNeeded(workspacePath: workspacePath)
        let path = connectionsFilePath(for: workspacePath)
        let hostFileAccess = HostFileAccessBroker()
        guard let data = try? hostFileAccess.readData(
            at: URL(fileURLWithPath: path),
            intent: .astraManagedStorage(root: URL(fileURLWithPath: workspacePath, isDirectory: true))
        ) else { return [] }
        return (try? JSONDecoder().decode([SSHConnection].self, from: data)) ?? []
    }

    private static func connectionFilePaths(for workspacePath: String) -> [String] {
        [
            WorkspaceFileLayout.sshConnectionsFile(for: workspacePath),
            WorkspaceFileLayout.legacySSHConnectionsFile(for: workspacePath)
        ].reduce(into: []) { paths, path in
            guard !path.isEmpty, !paths.contains(path) else { return }
            paths.append(path)
        }
    }

    static func save(
        _ connections: [SSHConnection],
        workspacePath: String,
        fileWriter: any SSHConnectionFileWriting = defaultFileWriter
    ) {
        WorkspaceFileLayout.ensureSupportDirectory(for: workspacePath)
        let path = connectionsFilePath(for: workspacePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(connections) else { return }
        try? fileWriter.writeAtomically(data, to: URL(fileURLWithPath: path))
    }

    private static func migrateLegacyConnectionsIfNeeded(workspacePath: String) {
        let canonical = WorkspaceFileLayout.sshConnectionsFile(for: workspacePath)
        let legacy = WorkspaceFileLayout.legacySSHConnectionsFile(for: workspacePath)
        guard !canonical.isEmpty,
              canonical != legacy,
              !FileManager.default.fileExists(atPath: canonical),
              FileManager.default.fileExists(atPath: legacy) else {
            return
        }

        do {
            WorkspaceFileLayout.ensureSupportDirectory(for: workspacePath)
            try FileManager.default.moveItem(atPath: legacy, toPath: canonical)
            AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
                "resource": "ssh_connections",
                "result": "completed"
            ])
        } catch {
            AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
                "resource": "ssh_connections",
                "result": "failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    /// Parsed host entry from an SSH config file.
    struct SSHConfigHost: Identifiable {
        let id = UUID()
        let name: String
        let hostname: String
        let user: String
        let port: Int
        let identityFile: String
        let hasProxyCommand: Bool
    }

    /// Parse hosts from an SSH config file (e.g., ~/.ssh/config).
    static func parseSSHConfig(at path: String) -> [SSHConfigHost] {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let content = try? HostFileAccessBroker().readString(
            at: URL(fileURLWithPath: expandedPath),
            encoding: .utf8,
            intent: .explicitUserSelection
        ) else { return [] }
        return parseSSHConfig(from: content)
    }

    /// Parse hosts from an SSH config string.
    static func parseSSHConfig(from content: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var currentName: String?
        var hostname = ""
        var user = ""
        var port = 22
        var identityFile = ""
        var hasProxy = false

        func flushHost() {
            if let name = currentName, !name.contains("*") {
                hosts.append(SSHConfigHost(
                    name: name,
                    hostname: hostname.isEmpty ? name : hostname,
                    user: user,
                    port: port,
                    identityFile: identityFile,
                    hasProxyCommand: hasProxy
                ))
            }
            currentName = nil
            hostname = ""
            user = ""
            port = 22
            identityFile = ""
            hasProxy = false
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map { String($0) }
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "host":
                flushHost()
                currentName = value
            case "hostname":
                hostname = value
            case "user":
                user = value
            case "port":
                port = Int(value) ?? 22
            case "identityfile":
                identityFile = value
            case "proxycommand":
                hasProxy = true
            default:
                break
            }
        }
        flushHost()

        return hosts
    }

    /// Convert a parsed SSH config host into an SSHConnection.
    static func connectionFromConfig(_ host: SSHConfigHost, remotePath: String = "~") -> SSHConnection {
        SSHConnection(
            name: host.name,
            host: host.hostname,
            user: host.user,
            port: host.port,
            remotePath: remotePath,
            keyPath: host.identityFile,
            configAlias: host.hasProxyCommand ? host.name : ""
        )
    }

    /// Test an SSH connection by running `ssh -o ConnectTimeout=5 <target> echo ok`.
    static func test(_ connection: SSHConnection) async -> (success: Bool, message: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            var args = ["-o", "ConnectTimeout=30", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]

            if !connection.configAlias.isEmpty {
                // Use the SSH config alias so ProxyCommand and other config directives are applied
                args += [connection.configAlias, "echo", "ok"]
            } else {
                if connection.port != 22 {
                    args += ["-p", "\(connection.port)"]
                }
                if !connection.keyPath.isEmpty {
                    args += ["-i", (connection.keyPath as NSString).expandingTildeInPath]
                }
                args += [connection.sshTarget, "echo", "ok"]
            }
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (false, "Failed to start SSH: \(error.localizedDescription)"))
                return
            }

            process.waitUntilExit()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 && stdout.contains("ok") {
                continuation.resume(returning: (true, "Connected successfully"))
            } else {
                let msg = stderr.isEmpty ? "Connection failed (exit \(process.terminationStatus))" : String(stderr.prefix(200))
                continuation.resume(returning: (false, msg))
            }
        }
    }
}

protocol SSHConnectionFileWriting {
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct AtomicSSHConnectionFileWriter: SSHConnectionFileWriting {
    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}
