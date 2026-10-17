import Foundation

/// What reading one file of a plugin source gave.
public enum PluginSourceFileRead: Equatable, Sendable {
    case data(Data)
    case missing
    /// Larger than the limit the caller passed; nothing was read.
    case tooLarge
    /// Outside the directory (after resolving symlinks), or unreadable.
    case refused
}

/// Read access to one plugin source's files, relative to a root. The app
/// implements it over its file-access broker, resolving symlinks; tests use
/// memory. Every path a source names goes through it, so nothing outside the
/// root is ever read (threat model T4).
public protocol PluginDirectoryReading {
    func read(_ relativePath: String, limit: Int) -> PluginSourceFileRead
    /// Names of the entries directly inside `relativeDirectory` ("" is the root).
    func entries(in relativeDirectory: String) -> [String]
    /// The same reader rooted at a subdirectory, or nil when that directory
    /// resolves outside this root. A plugin is read through its own scoped
    /// reader, so a symlink in it can't reach a sibling plugin either.
    func scoped(to relativeDirectory: String) -> PluginDirectoryReading?
}

/// Size and count limits for everything a source supplies (threat model
/// T11). A file over its limit is reported, never read.
public enum PluginSourceLimits {
    public static let marketplaceBytes = 256 * 1024
    public static let manifestBytes = 512 * 1024
    public static let skillBytes = 256 * 1024
    public static let maxEntries = 200
}

/// A plugin source's catalog: Claude Code's `.claude-plugin/marketplace.json`
/// shape, so one repository can serve both. ASTRA reads plugins whose
/// `source` is a path inside the repository; any other kind of source is
/// listed as unsupported rather than fetched.
public struct PluginMarketplace: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        /// A path inside the repository ("./plugins/jira"), when the entry's
        /// source is one.
        public var path: String?
        public var description: String?
    }

    public var name: String
    public var plugins: [Entry]

    public static let fileNames = [".claude-plugin/marketplace.json", "astra-marketplace.json"]

    public enum Read: Equatable, Sendable {
        /// No marketplace file: the source root is one plugin.
        case none
        case marketplace(PluginMarketplace)
        /// A marketplace file that can't be used, and why.
        case problem(String)
    }

    public static func read(from directory: PluginDirectoryReading) -> Read {
        for file in fileNames {
            switch directory.read(file, limit: PluginSourceLimits.marketplaceBytes) {
            case .missing:
                continue
            case .tooLarge:
                return .problem("\(file) is larger than \(PluginSourceLimits.marketplaceBytes / 1024) KB.")
            case .refused:
                return .problem("\(file) can't be read.")
            case .data(let data):
                return decode(data, file: file)
            }
        }
        return .none
    }

    static func decode(_ data: Data, file: String) -> Read {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["plugins"] as? [Any] else {
            return .problem("\(file) is not a marketplace file.")
        }
        guard entries.count <= PluginSourceLimits.maxEntries else {
            return .problem("\(file) lists \(entries.count) plugins; at most \(PluginSourceLimits.maxEntries) are read.")
        }
        var plugins: [Entry] = []
        for (index, raw) in entries.enumerated() {
            guard let entry = raw as? [String: Any], let name = entry["name"] as? String, !name.isEmpty else {
                return .problem("Entry \(index + 1) of \(file) has no name.")
            }
            plugins.append(Entry(
                name: name,
                path: entry["source"] as? String,
                description: entry["description"] as? String
            ))
        }
        return .marketplace(PluginMarketplace(name: object["name"] as? String ?? "", plugins: plugins))
    }
}

/// One plugin read from a source: its package, what of it ASTRA does not
/// run, and what keeps it from being added.
public struct PluginSourcePlugin: Sendable {
    public var package: PluginPackage
    /// Parts the source plugin has that ASTRA does not run ("2 agents", "hooks").
    public var unsupported: [String]
    /// Files that were too large, unreadable or malformed. A plugin with a
    /// problem is listed with it and offers no Add.
    public var problems: [String]
}

public enum PluginSourceReadError: Error, Equatable {
    case noManifest(String)
    case unsafePath(String)
    case tooLarge(String)
    case unreadable(String)
}

public enum PluginSourcePluginReader {
    /// Reads the plugin at `path` (relative to the source root), through a
    /// reader scoped to that directory: an ASTRA `capability.json` (package
    /// or manifest), else a Claude-layout plugin (`.claude-plugin/plugin.json`,
    /// `skills/*/SKILL.md`, `.mcp.json`).
    public static func read(at path: String, in source: PluginDirectoryReading) throws -> PluginSourcePlugin {
        let root = try normalized(path)
        guard let directory = root.isEmpty ? source : source.scoped(to: root) else {
            throw PluginSourceReadError.unsafePath(path)
        }
        switch directory.read("capability.json", limit: PluginSourceLimits.manifestBytes) {
        case .data(let data):
            var package = try PluginManifestConverter.decodePackage(from: data)
            var unsupported: [String] = []
            // Asset icons would be another path to read and copy; a source
            // plugin shows its symbol instead.
            if package.iconDescriptor.kind == .asset {
                package.iconDescriptor = .systemSymbol(package.icon)
                unsupported.append("custom icon")
            }
            return PluginSourcePlugin(package: package, unsupported: unsupported, problems: [])
        case .tooLarge:
            throw PluginSourceReadError.tooLarge("capability.json")
        case .refused:
            throw PluginSourceReadError.unreadable("capability.json")
        case .missing:
            break
        }
        switch directory.read(".claude-plugin/plugin.json", limit: PluginSourceLimits.manifestBytes) {
        case .data(let data):
            return try ClaudePluginConverter.plugin(manifestData: data, in: directory)
        case .tooLarge:
            throw PluginSourceReadError.tooLarge(".claude-plugin/plugin.json")
        case .refused:
            throw PluginSourceReadError.unreadable(".claude-plugin/plugin.json")
        case .missing:
            throw PluginSourceReadError.noManifest(root)
        }
    }

    /// A relative path inside the source: no `..`, no absolute path, no home
    /// shorthand, no backslash or control characters.
    public static func normalized(_ path: String) throws -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !parts.contains(".."),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw PluginSourceReadError.unsafePath(path)
        }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }
}

/// Converts a Claude Code plugin into a package. Skills and MCP servers map
/// directly; agents, hooks, commands and LSP servers have no ASTRA
/// equivalent and are reported, not dropped silently. The result is a local
/// draft that needs a person's approval.
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

    /// `directory` is the plugin's own scoped reader.
    public static func plugin(manifestData: Data, in directory: PluginDirectoryReading) throws -> PluginSourcePlugin {
        let info: PluginJSON
        do {
            info = try JSONDecoder().decode(PluginJSON.self, from: manifestData)
        } catch {
            throw PluginSourceReadError.unreadable(".claude-plugin/plugin.json")
        }
        var components: [PluginComponent] = []
        var problems: [String] = []
        let skillDirectories = directory.entries(in: "skills").sorted()
        if skillDirectories.count > PluginSourceLimits.maxEntries {
            problems.append("It has \(skillDirectories.count) skills; at most \(PluginSourceLimits.maxEntries) are read.")
        }
        for name in skillDirectories.prefix(PluginSourceLimits.maxEntries) {
            let path = "skills/\(name)/SKILL.md"
            switch directory.read(path, limit: PluginSourceLimits.skillBytes) {
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    problems.append("\(path) is not UTF-8 text.")
                    continue
                }
                let skill = skill(fromMarkdown: text, fallbackName: name)
                components.append(PluginComponent(
                    kind: .skill, id: PluginManifestConverter.slug(skill.name), name: skill.name,
                    summary: skill.description, skill: skill
                ))
            case .tooLarge:
                problems.append("\(path) is larger than \(PluginSourceLimits.skillBytes / 1024) KB.")
            case .refused:
                problems.append("\(path) can't be read.")
            case .missing:
                continue
            }
        }
        switch directory.read(".mcp.json", limit: PluginSourceLimits.manifestBytes) {
        case .data(let data):
            if let file = try? JSONDecoder().decode(MCPFile.self, from: data) {
                components += mcpComponents(file, pluginName: info.name)
            } else {
                problems.append(".mcp.json is not an MCP server file.")
            }
        case .tooLarge:
            problems.append(".mcp.json is larger than \(PluginSourceLimits.manifestBytes / 1024) KB.")
        case .refused:
            problems.append(".mcp.json can't be read.")
        case .missing:
            break
        }
        var unsupported: [String] = []
        for (folder, label) in [("agents", "agent"), ("commands", "command")] {
            let count = directory.entries(in: folder).count
            if count > 0 { unsupported.append(count == 1 ? "1 \(label)" : "\(count) \(label)s") }
        }
        if directory.read("hooks/hooks.json", limit: 1) != .missing { unsupported.append("hooks") }
        if directory.read(".lsp.json", limit: 1) != .missing { unsupported.append("LSP servers") }

        let id = PluginManifestConverter.slug(info.name)
        let manifest = PluginManifest(
            id: id.isEmpty ? "claude-plugin" : id,
            name: info.name,
            version: info.version ?? "0.0.0",
            summary: info.description ?? "",
            icon: "puzzlepiece.extension",
            author: info.author?.text ?? "Unknown",
            category: "Imported",
            worksOn: PluginManifestConverter.defaultWorksOn(
                hasMCP: components.contains { $0.kind == .mcp },
                hasShellComponents: components.contains { $0.kind != .mcp }
            ),
            components: components,
            governance: .localDraft()
        )
        return PluginSourcePlugin(
            package: PluginManifestConverter.package(from: manifest),
            unsupported: unsupported,
            problems: problems
        )
    }

    static func mcpComponents(_ file: MCPFile, pluginName: String) -> [PluginComponent] {
        var components: [PluginComponent] = []
        for (id, server) in file.mcpServers.sorted(by: { $0.key < $1.key }) {
            components.append(PluginComponent(
                kind: .mcp, id: id, name: id,
                setup: PluginComponentSetup(check: PluginSetupStep(kind: .processStarts)), mcp: mcpServer(id: id, server: server)
            ))
        }
        // The servers' environment keys become an account the person fills
        // in, so ASTRA declares them (an undeclared key blocks Add) and
        // supplies them from the Keychain; the file's values are dropped.
        let keys = Set(file.mcpServers.values.flatMap { ($0.env ?? [:]).keys }).sorted()
        if !keys.isEmpty {
            let name = "\(pluginName) settings"
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
        return components
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
