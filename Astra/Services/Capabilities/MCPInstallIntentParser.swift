import Foundation
import ASTRACore

struct MCPInstallIntent: Equatable {
    enum Kind: Equatable {
        case stdioCommand
        case remoteURL
    }

    var rawInput: String
    var kind: Kind
    var serverID: String?
    var displayName: String?
    var transport: PluginMCPServer.Transport
    var command: String?
    var arguments: [String]
    var url: URL?
    var installSource: PluginMCPInstallSource?
}

enum MCPInstallIntentParser {
    static func parse(_ input: String) -> MCPInstallIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let jsonIntent = parseClaudeConfig(trimmed) {
            return jsonIntent
        }
        guard !containsShellControl(trimmed) else { return nil }
        if let urlIntent = parseURL(trimmed) {
            return urlIntent
        }
        if let registryIntent = parseRegistryTarget(trimmed) {
            return registryIntent
        }
        return parseCommand(trimmed)
    }

    private static func parseURL(_ input: String) -> MCPInstallIntent? {
        guard let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return MCPInstallIntent(
            rawInput: input,
            kind: .remoteURL,
            serverID: defaultServerID(from: url.host ?? "remote"),
            displayName: url.host,
            transport: .http,
            command: nil,
            arguments: [],
            url: url,
            installSource: PluginMCPInstallSource(
                kind: .remoteHTTP,
                identifier: input,
                installMode: .remote
            )
        )
    }

    private static func parseRegistryTarget(_ input: String) -> MCPInstallIntent? {
        guard input.lowercased().hasPrefix("npm:") else { return nil }
        let packageTarget = String(input.dropFirst("npm:".count))
        guard let package = npmPackage(from: packageTarget) else { return nil }
        return MCPInstallIntent(
            rawInput: input,
            kind: .stdioCommand,
            serverID: defaultServerID(from: package.identifier),
            displayName: package.identifier,
            transport: .stdio,
            command: "npx",
            arguments: ["-y", packageTarget],
            url: nil,
            installSource: PluginMCPInstallSource(
                kind: .npm,
                identifier: package.identifier,
                version: package.version,
                installMode: .npx,
                registryURL: URL(string: "https://registry.npmjs.org/"),
                packageManagerArguments: ["-y"]
            )
        )
    }

    private static func parseCommand(_ input: String) -> MCPInstallIntent? {
        let tokens = shellTokens(input)
        guard let command = tokens.first else { return nil }
        let arguments = Array(tokens.dropFirst())
        let executable = (command as NSString).lastPathComponent.lowercased()

        let source: PluginMCPInstallSource
        if executable == "npx", let package = arguments.compactMap(npmPackage(from:)).first {
            source = PluginMCPInstallSource(
                kind: .npm,
                identifier: package.identifier,
                version: package.version,
                installMode: .npx,
                registryURL: URL(string: "https://registry.npmjs.org/"),
                packageManagerArguments: arguments.filter { $0.hasPrefix("-") }
            )
        } else if executable == "uvx", let package = arguments.compactMap(pypiPackage(from:)).first {
            source = PluginMCPInstallSource(
                kind: .pypi,
                identifier: package.identifier,
                version: package.version,
                installMode: .uvx,
                registryURL: URL(string: "https://pypi.org/simple/"),
                packageManagerArguments: arguments.filter { $0.hasPrefix("-") }
            )
        } else if executable == "docker", let image = dockerImage(from: arguments) {
            source = PluginMCPInstallSource(
                kind: .dockerImage,
                identifier: image.identifier,
                version: image.version,
                digest: image.digest,
                installMode: .dockerRun
            )
        } else {
            source = PluginMCPInstallSource(
                kind: .localBinary,
                identifier: command,
                installMode: command.hasPrefix("/") ? .localBinary : .globalBinary
            )
        }

        return MCPInstallIntent(
            rawInput: input,
            kind: .stdioCommand,
            serverID: defaultServerID(from: source.identifier),
            displayName: source.identifier,
            transport: .stdio,
            command: command,
            arguments: arguments,
            url: nil,
            installSource: source
        )
    }

    private static func parseClaudeConfig(_ input: String) -> MCPInstallIntent? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any],
              let first = servers.sorted(by: { $0.key < $1.key }).first,
              let entry = first.value as? [String: Any] else {
            return nil
        }

        if let urlText = entry["url"] as? String,
           var urlIntent = parseURL(urlText) {
            urlIntent.rawInput = input
            urlIntent.serverID = first.key
            return urlIntent
        }

        guard let command = entry["command"] as? String else { return nil }
        let args = entry["args"] as? [String] ?? []
        let commandLine = ([command] + args).joined(separator: " ")
        guard var intent = parseCommand(commandLine) else { return nil }
        intent.rawInput = input
        intent.serverID = first.key
        return intent
    }

    private static func containsShellControl(_ input: String) -> Bool {
        input.rangeOfCharacter(from: CharacterSet(charactersIn: ";|&`$<>(){}[]")) != nil
    }

    private static func shellTokens(_ input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func npmPackage(from token: String) -> (identifier: String, version: String?)? {
        guard !token.hasPrefix("-") else { return nil }
        guard !isFilesystemPath(token) else { return nil }
        if token.hasPrefix("@") {
            let body = token.dropFirst()
            guard let slash = body.firstIndex(of: "/"),
                  slash < body.index(before: body.endIndex) else {
                return nil
            }
            if let versionSeparator = body.lastIndex(of: "@"), versionSeparator > slash {
                let identifier = String(token[..<versionSeparator])
                let version = String(token[token.index(after: versionSeparator)...])
                guard !version.isEmpty else { return nil }
                return (identifier, version)
            }
            return (token, nil)
        }
        guard token.localizedCaseInsensitiveContains("mcp") else { return nil }
        if let at = token.lastIndex(of: "@") {
            let identifier = String(token[..<at])
            let version = String(token[token.index(after: at)...])
            guard !identifier.isEmpty, !version.isEmpty else { return nil }
            return (identifier, version)
        }
        return (token, nil)
    }

    private static func pypiPackage(from token: String) -> (identifier: String, version: String?)? {
        guard !token.hasPrefix("-") else { return nil }
        guard token.localizedCaseInsensitiveContains("mcp") else { return nil }
        if let exactRange = token.range(of: "==") {
            let identifier = String(token[..<exactRange.lowerBound])
            let version = String(token[exactRange.upperBound...])
            guard !identifier.isEmpty, !version.isEmpty else { return nil }
            return (identifier, version)
        }
        return (token, nil)
    }

    private static func dockerImage(from arguments: [String]) -> (identifier: String, version: String?, digest: String?)? {
        var index = arguments.first == "run" ? 1 : 0
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("-") {
                index += dockerOptionConsumesNextValue(token) ? 2 : 1
                continue
            }
            if isDockerImageReference(token) {
                return dockerImageParts(from: token)
            }
            index += 1
        }
        return nil
    }

    private static func dockerImageParts(from image: String) -> (identifier: String, version: String?, digest: String?) {
        if let digestRange = image.range(of: "@sha256:") {
            return (String(image[..<digestRange.lowerBound]), nil, String(image[digestRange.upperBound...]))
        }
        if let colon = image.lastIndex(of: ":"),
           image.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            return (String(image[..<colon]), String(image[image.index(after: colon)...]), nil)
        }
        return (image, nil, nil)
    }

    private static func isDockerImageReference(_ token: String) -> Bool {
        guard !isFilesystemPath(token),
              !token.contains("=") else {
            return false
        }
        return token.contains("/")
            || token.localizedCaseInsensitiveContains("mcp")
            || token.contains("@sha256:")
            || token.lastIndex(of: ":").map { colon in
                token.lastIndex(of: "/").map { colon > $0 } ?? true
            } ?? false
    }

    private static func dockerOptionConsumesNextValue(_ token: String) -> Bool {
        let option = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        guard option == token else { return false }
        return [
            "-e", "--env", "--env-file", "--name", "--hostname", "-h",
            "-p", "--publish", "--expose", "-v", "--volume", "--mount",
            "-w", "--workdir", "-u", "--user", "--network", "--platform",
            "--entrypoint", "--add-host", "--label", "--log-driver",
            "--log-opt", "--pull"
        ].contains(option)
    }

    private static func isFilesystemPath(_ token: String) -> Bool {
        token.hasPrefix("/")
            || token.hasPrefix("./")
            || token.hasPrefix("../")
            || token.hasPrefix("~/")
            || token.hasPrefix("file:")
    }

    private static func defaultServerID(from value: String) -> String {
        let base = value
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let allowed = base.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : "-"
        }
        let normalized = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return normalized.isEmpty ? "mcp" : normalized
    }
}
