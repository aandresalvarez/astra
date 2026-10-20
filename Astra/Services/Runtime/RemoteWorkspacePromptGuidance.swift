import ASTRAPersistence

enum RemoteWorkspacePromptGuidance {
    /// Keeps remote work durable without turning a provider shell call into the scheduler.
    static let longRunningCommandContract = """
    Long-running remote command contract: only launch multi-hour remote work when a reviewed workspace capability explicitly authorizes remote execution. Launch it detached with file-backed logs or status files so it survives SSH disconnects. Keep each SSH or Bash tool call bounded to one launch or one status read; never hold a tool call open with `sleep` or an internal polling loop. Do not replace a long wait with rapid repeated checks. Return the durable external handle, latest verified status, and recovery paths, then end the provider turn. Do not claim ASTRA will continue monitoring unless an explicit ASTRA operation-monitoring capability registered the job.
    """

    /// The workspace's SSH connections, and how this run reaches them. The
    /// "how" is the launch's resolved route and nothing else: without one
    /// (a prompt built outside a launch) the block describes the servers and
    /// makes no claim about a shell or tool the run may not have.
    static func connectionBlock(connections: [SSHConnection], route: RemoteWorkspaceSSHRoute?) -> String? {
        guard !connections.isEmpty else { return nil }
        var block: String
        if connections.count == 1, let conn = connections.first {
            let alias = RemoteWorkspaceSSHRoute.connectAlias(for: conn)
            block = "Remote Server: This workspace is connected to a remote server via SSH."
            block += "\n- Name: \(conn.displayLabel)"
            block += "\n- Connect with: ssh \(alias)"
            block += "\n- Remote path: \(conn.remotePath)"
            if !conn.configAlias.isEmpty { block += "\n- SSH config: this alias requires ~/.ssh/config and may include ProxyCommand/IAP settings; prefer the alias over the raw hostname." }
            if !conn.keyPath.isEmpty { block += "\n- Identity file: \(conn.keyPath)" }
            block += "\nWhen the user says \"the server\", \"the remote\", \"this connection\", or \"it\" in the context of SSH, they mean this server."
        } else {
            block = "Available SSH Connections:"
            for conn in connections {
                block += "\n- \(conn.displayLabel): ssh \(RemoteWorkspaceSSHRoute.connectAlias(for: conn)) (remote path: \(conn.remotePath))"
                if !conn.configAlias.isEmpty { block += " [uses ~/.ssh/config alias; may include ProxyCommand/IAP]" }
                if !conn.keyPath.isEmpty { block += " [identity: \(conn.keyPath)]" }
            }
        }
        if let route {
            block += "\n\(route.instruction)"
        }
        block += "\n\(longRunningCommandContract)"
        return block
    }
}
