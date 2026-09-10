import Darwin
import Foundation

/// What the configured Codex CLI reported about one MCP server definition.
struct CodexMCPPolicyProbeResult: Equatable, Sendable {
    /// Whether the CLI listed the probe's own server definition as enabled.
    var serverEnabled: Bool
    /// The provider's verbatim explanation, when it refused the server.
    var disabledReason: String?
}

protocol CodexMCPPolicyProbing: Sendable {
    func probe(
        serverID: String,
        command: String,
        executablePath: String,
        environment: [String: String]
    ) async throws -> CodexMCPPolicyProbeResult
}

enum CodexMCPPolicyProbeError: Error, LocalizedError, Equatable {
    case unavailableExecutable
    case timedOut
    case exited(status: Int32)
    case invalidResponse
    case probeServerMissing

    var errorDescription: String? {
        switch self {
        case .unavailableExecutable: "No runnable Codex CLI was found for the MCP policy check."
        case .timedOut: "The Codex MCP policy check timed out."
        case .exited(let status): "Codex could not list its MCP servers (exit \(status))."
        case .invalidResponse: "Codex returned an MCP server list ASTRA could not read."
        case .probeServerMissing: "Codex did not report back the MCP server ASTRA asked it about."
        }
    }
}

/// Asks the configured Codex CLI whether it would accept an MCP server ASTRA
/// supplies, by handing it one on the command line and reading back its own
/// verdict: `codex mcp list --json -c mcp_servers.<id>={command=...}`.
///
/// Defining the server inline rather than reading whatever the user happens to
/// have configured is what makes the answer general. It needs no pre-existing
/// entries, it asks about the exact server name ASTRA injects at launch, and a
/// server ASTRA just defined cannot come back disabled because a *user* turned
/// it off — only because something outside the config refused it.
///
/// `mcp list` reads configuration and policy. It starts no server, opens no
/// session, and spends no tokens; the referenced command is never executed, so
/// the probe stays honest even when the broker helper is not installed yet.
struct CodexMCPListPolicyProbe: CodexMCPPolicyProbing {
    var timeout: TimeInterval = 10

    func probe(
        serverID: String,
        command: String,
        executablePath: String,
        environment: [String: String]
    ) async throws -> CodexMCPPolicyProbeResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try run(
                        serverID: serverID,
                        command: command,
                        executablePath: executablePath,
                        environment: environment
                    )
                })
            }
        }
    }

    private func run(
        serverID: String,
        command: String,
        executablePath: String,
        environment: [String: String]
    ) throws -> CodexMCPPolicyProbeResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexMCPPolicyProbeError.unavailableExecutable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "mcp", "list", "--json",
            "-c", "mcp_servers.\(serverID)={command=\(Self.tomlString(command))}"
        ]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        // Provider diagnostics can carry account details; keep them out of ASTRA.
        process.standardError = FileHandle.nullDevice

        let buffer = ProbeOutputBuffer()
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            buffer.finish(reader.readDataToEndOfFile())
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw CodexMCPPolicyProbeError.unavailableExecutable
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CodexMCPPolicyProbeError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw CodexMCPPolicyProbeError.exited(status: process.terminationStatus)
        }
        guard let data = buffer.wait(timeout: .now() + 1) else {
            throw CodexMCPPolicyProbeError.timedOut
        }
        return try Self.parse(data, serverID: serverID)
    }

    static func parse(_ data: Data, serverID: String) throws -> CodexMCPPolicyProbeResult {
        // Tolerate a banner ahead of the array: only the JSON document matters.
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data[start...]) else {
            throw CodexMCPPolicyProbeError.invalidResponse
        }
        guard let entry = entries.first(where: { $0.name == serverID }) else {
            throw CodexMCPPolicyProbeError.probeServerMissing
        }
        // A CLI that does not report the field has not told us anything. Saying
        // "enabled" here would invent permission; saying "disabled" would block
        // a launch on a parsing gap. Neither is an answer, so refuse to give one.
        guard let enabled = entry.enabled else {
            throw CodexMCPPolicyProbeError.invalidResponse
        }
        return CodexMCPPolicyProbeResult(
            serverEnabled: enabled,
            disabledReason: enabled ? nil : entry.disabledReason
        )
    }

    /// TOML basic string, so a path containing a quote or backslash cannot
    /// change the shape of the `-c` override ASTRA passes.
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private struct Entry: Decodable {
        var name: String
        var enabled: Bool?
        var disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case name
            case enabled
            case disabledReason = "disabled_reason"
        }
    }
}
