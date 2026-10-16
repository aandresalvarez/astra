import Foundation

/// Read access to one plugin source's files, relative to its root. The app
/// implements it over its file-access broker; tests use memory.
public protocol PluginDirectoryReading {
    func data(at relativePath: String) -> Data?
    /// Names of the entries directly inside `relativeDirectory` ("" is the root).
    func entries(in relativeDirectory: String) -> [String]
}

/// A plugin source's catalog: Claude Code's `.claude-plugin/marketplace.json`
/// shape, so one repository can serve both. ASTRA reads plugins whose
/// `source` is a path inside the repository; other source kinds are listed as
/// unsupported rather than fetched.
public struct PluginMarketplace: Codable, Sendable, Equatable {
    public struct Owner: Codable, Sendable, Equatable {
        public var name: String
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        /// A path inside the repository ("./plugins/jira"), when the source is one.
        public var path: String?
        public var description: String?
        public var version: String?

        enum CodingKeys: String, CodingKey { case name, source, description, version }

        public init(name: String, path: String?, description: String? = nil, version: String? = nil) {
            self.name = name
            self.path = path
            self.description = description
            self.version = version
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            path = try? c.decode(String.self, forKey: .source)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(path, forKey: .source)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encodeIfPresent(version, forKey: .version)
        }
    }

    public var name: String
    public var owner: Owner?
    public var plugins: [Entry]

    public static let fileNames = [".claude-plugin/marketplace.json", "astra-marketplace.json"]

    public static func read(from directory: PluginDirectoryReading) throws -> PluginMarketplace? {
        for file in fileNames {
            if let data = directory.data(at: file) {
                return try JSONDecoder().decode(PluginMarketplace.self, from: data)
            }
        }
        return nil
    }
}

/// One plugin read from a source, and what of it ASTRA could not bring over.
public struct PluginSourcePlugin: Sendable {
    public var manifest: PluginManifest
    /// Parts the source plugin has that ASTRA does not run ("2 agents", "hooks").
    public var unsupported: [String]
}

public enum PluginSourceReadError: Error, Equatable {
    case noManifest(String)
    case unsafePath(String)
}

public enum PluginSourcePluginReader {
    /// Reads the plugin at `path` (relative to the source root): an ASTRA
    /// `capability.json` (package or manifest), else a Claude-layout plugin
    /// (`.claude-plugin/plugin.json`, `skills/*/SKILL.md`, `.mcp.json`).
    public static func read(at path: String, in source: PluginDirectoryReading) throws -> PluginSourcePlugin {
        let root = try normalized(path)
        if let data = source.data(at: join(root, "capability.json")) {
            let package = try PluginManifestConverter.decodePackage(from: data)
            return PluginSourcePlugin(manifest: PluginManifestConverter.manifest(from: package), unsupported: [])
        }
        guard let data = source.data(at: join(root, ".claude-plugin/plugin.json")) else {
            throw PluginSourceReadError.noManifest(root)
        }
        return try ClaudePluginConverter.plugin(manifestData: data, root: root, in: source)
    }

    /// Rejects paths that leave the source ("../"), which a marketplace file
    /// could otherwise use to read anything on disk.
    static func normalized(_ path: String) throws -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !trimmed.hasPrefix("/"), !parts.contains("..") else {
            throw PluginSourceReadError.unsafePath(path)
        }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    static func join(_ root: String, _ child: String) -> String {
        root.isEmpty ? child : "\(root)/\(child)"
    }
}

/// Converts a Claude Code plugin into a Plugins 2.0 manifest. Skills and MCP
/// servers map directly; agents, hooks, commands and LSP servers have no ASTRA
/// equivalent and are reported, not dropped silently. The result is a local
/// draft: adding it still asks nothing, but the approval is the person's.
public enum ClaudePluginConverter {
    struct PluginJSON: Decodable {
        var name: String
        var version: String?
        var description: String?
        var author: Author?

        enum Author: Decodable {
            case name(String)
            case object(String)

            init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self) {
                    self = .name(value)
                    return
                }
                struct Object: Decodable { var name: String }
                self = .object(try Object(from: decoder).name)
            }

            var text: String {
                switch self {
                case .name(let value), .object(let value): value
                }
            }
        }
    }

    struct MCPFile: Decodable {
        struct Server: Decodable {
            var command: String?
            var args: [String]?
            var env: [String: String]?
            var url: String?
            var type: String?
        }

        var mcpServers: [String: Server]
    }

    public static func plugin(manifestData: Data, root: String, in source: PluginDirectoryReading) throws -> PluginSourcePlugin {
        let info = try JSONDecoder().decode(PluginJSON.self, from: manifestData)
        var components: [PluginComponent] = []
        for directory in source.entries(in: PluginSourcePluginReader.join(root, "skills")).sorted() {
            let path = PluginSourcePluginReader.join(root, "skills/\(directory)/SKILL.md")
            guard let data = source.data(at: path) else { continue }
            let skill = skill(fromMarkdown: String(decoding: data, as: UTF8.self), fallbackName: directory)
            components.append(PluginComponent(
                kind: .skill, id: PluginManifestConverter.slug(skill.name), name: skill.name,
                summary: skill.description, skill: skill
            ))
        }
        if let data = source.data(at: PluginSourcePluginReader.join(root, ".mcp.json")),
           let file = try? JSONDecoder().decode(MCPFile.self, from: data) {
            for (id, server) in file.mcpServers.sorted(by: { $0.key < $1.key }) {
                let mcp = mcpServer(id: id, server: server)
                components.append(PluginComponent(
                    kind: .mcp, id: id, name: id,
                    setup: PluginComponentSetup(check: PluginSetupStep(kind: .processStarts)), mcp: mcp
                ))
            }
            // The servers' environment keys become an account the person fills
            // in, so ASTRA declares them (an undeclared key blocks Add) and
            // supplies them from the Keychain; the file's values are dropped.
            let keys = Set(file.mcpServers.values.flatMap { ($0.env ?? [:]).keys }).sorted()
            if !keys.isEmpty {
                let name = "\(info.name) settings"
                components.append(PluginComponent(
                    kind: .connector, id: PluginManifestConverter.slug(name), name: name,
                    summary: "Values the plugin's MCP servers read from the environment.",
                    connector: PluginConnector(
                        name: name, serviceType: "custom", icon: "key",
                        description: "Values the plugin's MCP servers read from the environment.",
                        baseURL: "", authMethod: "api_key",
                        credentialHints: keys.map { PluginConnector.CredentialHint(key: $0, hint: "Used by the plugin's MCP server") },
                        configHints: [], notes: ""
                    )
                ))
            }
        }
        var unsupported: [String] = []
        for (folder, label) in [("agents", "agent"), ("commands", "command")] {
            let count = source.entries(in: PluginSourcePluginReader.join(root, folder)).count
            if count > 0 { unsupported.append(count == 1 ? "1 \(label)" : "\(count) \(label)s") }
        }
        if source.data(at: PluginSourcePluginReader.join(root, "hooks/hooks.json")) != nil { unsupported.append("hooks") }
        if source.data(at: PluginSourcePluginReader.join(root, ".lsp.json")) != nil { unsupported.append("LSP servers") }

        let id = PluginManifestConverter.slug(info.name)
        let manifest = PluginManifest(
            id: id.isEmpty ? "claude-plugin" : id,
            name: info.name,
            version: info.version ?? "0.0.0",
            summary: info.description ?? "",
            icon: "puzzlepiece.extension",
            author: info.author?.text ?? "Unknown",
            category: "Imported",
            worksOn: PluginManifestConverter.defaultWorksOn(hasMCP: components.contains { $0.kind == .mcp }),
            components: components,
            governance: .localDraft()
        )
        return PluginSourcePlugin(manifest: manifest, unsupported: unsupported)
    }

    /// A `SKILL.md`: optional `---` frontmatter with `name`, `description` and
    /// `allowed-tools`, then the instructions.
    public static func skill(fromMarkdown text: String, fallbackName: String) -> PluginSkill {
        var fields: [String: String] = [:]
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        let tools = (fields["allowed-tools"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return PluginSkill(
            name: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            icon: "sparkles",
            description: fields["description"] ?? "",
            allowedTools: tools,
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            environmentKeys: [],
            environmentValues: []
        )
    }

    static func mcpServer(id: String, server: MCPFile.Server) -> PluginMCPServer {
        if let url = server.url.flatMap(URL.init(string:)) {
            return PluginMCPServer(
                id: id, displayName: id, transport: server.type == "sse" ? .sse : .http, url: url
            )
        }
        return PluginMCPServer(
            id: id,
            displayName: id,
            transport: .stdio,
            command: server.command,
            arguments: server.args ?? [],
            // Values stay out: a plugin's .mcp.json env can carry secrets, and
            // ASTRA supplies environment values from its own Keychain.
            environmentKeys: (server.env ?? [:]).keys.sorted()
        )
    }
}
