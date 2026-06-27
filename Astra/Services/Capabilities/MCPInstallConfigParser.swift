import Foundation
import ASTRACore

enum MCPInstallConfigParser {
    static func parse(
        _ input: String,
        commandParser: (String, [String], String) -> MCPInstallIntent?
    ) -> MCPInstallIntent? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else {
            return nil
        }

        var specs: [MCPInstallServerSpec] = []
        for (key, value) in servers.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any],
                  let spec = serverSpec(serverID: key, entry: entry, commandParser: commandParser) else {
                return nil
            }
            specs.append(spec)
        }
        guard let first = specs.first else { return nil }

        return MCPInstallIntent(
            rawInput: input,
            kind: .configJSON,
            serverID: first.serverID,
            displayName: first.displayName,
            transport: first.transport,
            command: first.command,
            arguments: first.arguments,
            url: first.url,
            installSource: first.installSource,
            serverSpecs: specs
        )
    }

    private static func serverSpec(
        serverID: String,
        entry: [String: Any],
        commandParser: (String, [String], String) -> MCPInstallIntent?
    ) -> MCPInstallServerSpec? {
        if let urlText = entry["url"] as? String,
           let url = URL(string: urlText) {
            let type = (entry["type"] as? String)?.lowercased()
            let transport: PluginMCPServer.Transport = type == "sse" ? .sse : .http
            return MCPInstallServerSpec(
                serverID: serverID,
                displayName: displayName(from: entry, fallback: serverID),
                transport: transport,
                command: nil,
                arguments: [],
                url: url,
                environmentKeys: environmentKeys(from: entry),
                installSource: PluginMCPInstallSource(
                    kind: .remoteHTTP,
                    identifier: urlText,
                    installMode: .remote
                )
            )
        }

        guard let command = entry["command"] as? String else { return nil }
        let args = entry["args"] as? [String] ?? []
        let commandLine = ([command] + args).joined(separator: " ")
        guard let intent = commandParser(command, args, commandLine),
              intent.kind == .stdioCommand,
              var spec = intent.serverSpecs.first else {
            return nil
        }
        spec.serverID = serverID
        spec.displayName = displayName(from: entry, fallback: serverID)
        spec.environmentKeys = environmentKeys(from: entry)
        return spec
    }

    private static func displayName(from entry: [String: Any], fallback: String) -> String {
        let candidates = [
            entry["displayName"] as? String,
            entry["name"] as? String,
            fallback
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallback
    }

    private static func environmentKeys(from entry: [String: Any]) -> [String] {
        guard let env = entry["env"] as? [String: Any] else { return [] }
        return env.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
