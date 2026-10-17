import Foundation

/// The Plugins 2.0 manifest (`docs/specs/2026-10-15-plugins-2-capability-redesign.md`).
///
/// A plugin is one list of components, each of one kind (skill, connector,
/// tool, MCP server, template, setup step), and every component carries the
/// same setup contract: how to `check` it without the user, `verify` it over
/// the network, `connect` it with the user, `repair` it once it breaks, and
/// `install` what it needs. `worksOn` says, per runtime, whether the plugin
/// works fully, only through the shell relay, or not at all.
///
/// Component payloads are the existing package types unchanged, so converting
/// to and from `PluginPackage` is lossless and everything below the package
/// (library, installer, resolver, runtime) keeps working: a manifest projects
/// into today's rows through `PluginManifestConverter.package(from:)`.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Marks the file as a Plugins 2.0 manifest rather than a package.
    public var manifestVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var summary: String
    public var icon: String
    public var iconDescriptor: CapabilityIconDescriptor?
    public var author: String
    public var category: String
    public var tags: [String]
    public var setupGuide: String
    /// Runtime ID (`claude_code`, `codex`, …) → how much of the plugin works there.
    public var worksOn: [String: PluginRuntimeSupport]
    public var components: [PluginComponent]
    public var browserAdapters: [String]
    public var minAppVersion: String?
    public var requires: [String]?
    public var conflicts: [String]?
    public var sourceMetadata: CapabilitySourceMetadata?
    public var governance: CapabilityGovernance?

    public static let currentVersion = 1

    public init(
        id: String,
        name: String,
        version: String,
        summary: String,
        icon: String,
        iconDescriptor: CapabilityIconDescriptor? = nil,
        author: String,
        category: String,
        tags: [String] = [],
        setupGuide: String = "",
        worksOn: [String: PluginRuntimeSupport],
        components: [PluginComponent],
        browserAdapters: [String] = [],
        minAppVersion: String? = nil,
        requires: [String]? = nil,
        conflicts: [String]? = nil,
        sourceMetadata: CapabilitySourceMetadata? = nil,
        governance: CapabilityGovernance? = nil
    ) {
        self.manifestVersion = Self.currentVersion
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.icon = icon
        self.iconDescriptor = iconDescriptor
        self.author = author
        self.category = category
        self.tags = tags
        self.setupGuide = setupGuide
        self.worksOn = worksOn
        self.components = components
        self.browserAdapters = browserAdapters
        self.minAppVersion = minAppVersion
        self.requires = requires
        self.conflicts = conflicts
        self.sourceMetadata = sourceMetadata
        self.governance = governance
    }

    public static func == (lhs: PluginManifest, rhs: PluginManifest) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

/// How much of a plugin works on one runtime. MCP servers reach Claude, Codex
/// and (when its CLI supports it) Copilot; the others get the shell relay only.
public enum PluginRuntimeSupport: String, Codable, Sendable, Equatable {
    case full
    /// Copilot receives MCP servers only when its installed CLI accepts
    /// `--additional-mcp-config`.
    case fullWithRecentCLI = "full-with-recent-cli"
    case shellOnly = "shell-only"
    case unsupported
}

public struct PluginComponent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case skill, connector, tool, mcp, template
        /// A CLI the plugin needs, or an account step, with no row of its own.
        case setup
    }

    public var kind: Kind
    /// Stable within the plugin. For a skill, connector or tool it is the
    /// component's identity: converting to a package carries it onto the
    /// payload's `id` whenever it differs from the name-derived default, so
    /// renaming a component that keeps its `id` keeps its settings,
    /// accounts and secrets. Defaults to `defaultID(forName:)`.
    public var id: String
    public var name: String
    public var summary: String
    public var setup: PluginComponentSetup

    public var skill: PluginSkill?
    public var connector: PluginConnector?
    public var tool: PluginLocalTool?
    public var mcp: PluginMCPServer?
    public var template: PluginTemplate?
    /// For `setup` components: a CLI prerequisite or an account requirement.
    public var requirement: PluginSetupRequirement?

    /// The identity a component without an explicit `id` derives from its
    /// name. `CapabilityResourceOrigin` normalizes with this same function,
    /// so a default `id` and the name it came from name the same component.
    public static func defaultID(forName name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public init(
        kind: Kind,
        id: String,
        name: String,
        summary: String = "",
        setup: PluginComponentSetup = PluginComponentSetup(),
        skill: PluginSkill? = nil,
        connector: PluginConnector? = nil,
        tool: PluginLocalTool? = nil,
        mcp: PluginMCPServer? = nil,
        template: PluginTemplate? = nil,
        requirement: PluginSetupRequirement? = nil
    ) {
        self.kind = kind
        self.id = id
        self.name = name
        self.summary = summary
        self.setup = setup
        self.skill = skill
        self.connector = connector
        self.tool = tool
        self.mcp = mcp
        self.template = template
        self.requirement = requirement
    }
}

/// The setup contract every component shares. `check` never needs the user and
/// runs on add and on refresh; `verify` may use the network; `connect` needs the
/// user and is never run at add time; `repair` is what a broken component's
/// button does; `install` gets a missing dependency.
public enum PluginManifestError: Error, Equatable, LocalizedError {
    /// A component declares setup steps ASTRA cannot run yet.
    case unrepresentableSetup(component: String)
    /// A manifest version this build doesn't know.
    case unsupportedVersion(Int)
    /// `worksOn` keeps the plugin off runtimes ASTRA would run it on.
    case unenforcedRuntimeRestriction(runtime: String)
    /// A component without its kind's payload, or with another kind's.
    case mismatchedPayload(component: String)
    /// A component ID the package can't carry: it would be re-derived from
    /// the payload's name, so the declared ID would not survive conversion.
    case unrepresentableComponentID(component: String, id: String)

    public var errorDescription: String? {
        switch self {
        case .unrepresentableSetup(let component):
            "\(component) declares setup steps ASTRA can't run yet, so the plugin can't be installed."
        case .unsupportedVersion(let version):
            "This plugin uses manifest version \(version), which this version of ASTRA doesn't read."
        case .mismatchedPayload(let component):
            "\(component) doesn't carry the definition its kind needs, so the plugin can't be installed."
        case .unenforcedRuntimeRestriction(let runtime):
            "The plugin says it doesn't work on \(runtime), and ASTRA can't keep it off that runtime yet."
        case .unrepresentableComponentID(let component, let id):
            "\(component) declares the ID \"\(id)\", which ASTRA can't keep yet, so the plugin can't be installed."
        }
    }
}

public struct PluginComponentSetup: Codable, Sendable, Equatable {
    public var check: PluginSetupStep?
    public var verify: PluginSetupStep?
    public var connect: PluginSetupStep?
    public var repair: PluginSetupStep?
    public var install: PluginSetupStep?

    public init(
        check: PluginSetupStep? = nil,
        verify: PluginSetupStep? = nil,
        connect: PluginSetupStep? = nil,
        repair: PluginSetupStep? = nil,
        install: PluginSetupStep? = nil
    ) {
        self.check = check
        self.verify = verify
        self.connect = connect
        self.repair = repair
        self.install = install
    }

    public var isEmpty: Bool { self == PluginComponentSetup() }
}

public struct PluginSetupStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// Run `binary` with `arguments`; `expect` names a semantic check.
        case exec
        /// A Keychain credential is stored for the component.
        case credentialPresent
        /// An HTTP probe at `path` relative to the connector's base URL.
        case http
        /// The MCP server process starts.
        case processStarts
        /// Run `command` in Terminal; ASTRA re-checks until it passes.
        case terminal
        /// Open `url` (OAuth, install page); ASTRA re-checks on return.
        case url
        /// A device-code sign-in inside ASTRA (GitHub-style).
        case deviceCode
        /// Ask for `fields` and store them in the Keychain.
        case credentialForm
    }

    public var kind: Kind
    public var binary: String?
    public var arguments: [String]?
    public var expect: String?
    public var context: String?
    public var command: String?
    public var url: URL?
    public var path: String?
    public var fields: [String]?
    /// What the person reads next to the button.
    public var hint: String?

    public init(
        kind: Kind,
        binary: String? = nil,
        arguments: [String]? = nil,
        expect: String? = nil,
        context: String? = nil,
        command: String? = nil,
        url: URL? = nil,
        path: String? = nil,
        fields: [String]? = nil,
        hint: String? = nil
    ) {
        self.kind = kind
        self.binary = binary
        self.arguments = arguments
        self.expect = expect
        self.context = context
        self.command = command
        self.url = url
        self.path = path
        self.fields = fields
        self.hint = hint
    }
}

/// Converts between `PluginManifest` and today's `PluginPackage`.
public enum PluginManifestConverter {
    /// Runtimes that receive MCP servers directly; the rest get the shell relay.
    public static let mcpRuntimes: Set<String> = [AgentRuntimeID.claudeCode.rawValue, AgentRuntimeID.codexCLI.rawValue]
    public static let conditionalMCPRuntimes: Set<String> = [AgentRuntimeID.copilotCLI.rawValue]
    public static let shellOnlyRuntimes: Set<String> = [
        AgentRuntimeID.cursorCLI.rawValue, AgentRuntimeID.openCodeCLI.rawValue, AgentRuntimeID.antigravityCLI.rawValue
    ]

    public static func manifest(from package: PluginPackage) -> PluginManifest {
        var components: [PluginComponent] = []
        components += package.skills.map {
            PluginComponent(kind: .skill, id: $0.id ?? PluginComponent.defaultID(forName: $0.name), name: $0.name, summary: $0.description, skill: $0)
        }
        components += package.connectors.map {
            PluginComponent(
                kind: .connector, id: $0.id ?? PluginComponent.defaultID(forName: $0.name), name: $0.name, summary: $0.description,
                setup: connectorSetup($0), connector: $0
            )
        }
        components += package.localTools.map {
            PluginComponent(kind: .tool, id: $0.id ?? PluginComponent.defaultID(forName: $0.name), name: $0.name, summary: $0.description, tool: $0)
        }
        components += package.mcpServers.map {
            PluginComponent(
                kind: .mcp, id: $0.id, name: $0.displayName,
                setup: PluginComponentSetup(check: PluginSetupStep(kind: .processStarts)), mcp: $0
            )
        }
        components += package.templates.map {
            PluginComponent(kind: .template, id: slug($0.name), name: $0.name, summary: $0.description, template: $0)
        }
        components += package.prerequisites.map(setupComponent)
        components += package.setupRequirements.map {
            PluginComponent(kind: .setup, id: $0.id, name: $0.displayName, summary: $0.notes, requirement: $0)
        }
        return PluginManifest(
            id: package.id,
            name: package.name,
            version: package.version,
            summary: package.description,
            icon: package.icon,
            iconDescriptor: package.iconDescriptor,
            author: package.author,
            category: package.category,
            tags: package.tags,
            setupGuide: package.setupGuide,
            worksOn: defaultWorksOn(
                hasMCP: !package.mcpServers.isEmpty,
                hasShellComponents: !package.skills.isEmpty || !package.connectors.isEmpty || !package.localTools.isEmpty
            ),
            components: components,
            browserAdapters: package.browserAdapters,
            minAppVersion: package.minAppVersion,
            requires: package.requires,
            conflicts: package.conflicts,
            sourceMetadata: package.sourceMetadata,
            governance: package.governance
        )
    }

    public static func package(from manifest: PluginManifest) -> PluginPackage {
        var package = PluginPackage(
            id: manifest.id,
            name: manifest.name,
            icon: manifest.icon,
            iconDescriptor: manifest.iconDescriptor,
            description: manifest.summary,
            author: manifest.author,
            category: manifest.category,
            tags: manifest.tags,
            version: manifest.version,
            setupGuide: manifest.setupGuide,
            skills: manifest.components.compactMap(identifiedSkill),
            connectors: manifest.components.compactMap(identifiedConnector),
            localTools: manifest.components.compactMap(identifiedTool),
            mcpServers: manifest.components.compactMap(\.mcp),
            templates: manifest.components.compactMap(\.template),
            setupRequirements: manifest.components.compactMap(\.requirement),
            browserAdapters: manifest.browserAdapters,
            prerequisites: manifest.components.filter { $0.kind == .setup && $0.requirement == nil }
                .compactMap(prerequisite),
            sourceMetadata: manifest.sourceMetadata,
            governance: manifest.governance
        )
        package.minAppVersion = manifest.minAppVersion
        package.requires = manifest.requires
        package.conflicts = manifest.conflicts
        return package
    }

    /// Decodes either format: a Plugins 2.0 manifest (it has `components`) is
    /// converted, anything else decodes as a package.
    public static func decodePackage(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> PluginPackage {
        if isManifest(data) {
            return try checkedPackage(from: decoder.decode(PluginManifest.self, from: data))
        }
        return try decoder.decode(PluginPackage.self, from: data)
    }

    /// The payload with the component's `id` as its identity. A default
    /// `id` (the one its name derives) is left off, so a package converted
    /// to a manifest and back is unchanged. A payload that gains an `id`
    /// here also replaces the identity its name derives: an earlier ASTRA
    /// dropped the component's `id`, so an activation it made keys this
    /// component's settings, accounts and secrets by that name.
    private static func identifiedSkill(_ component: PluginComponent) -> PluginSkill? {
        guard var skill = component.skill else { return nil }
        if component.id != PluginComponent.defaultID(forName: skill.name) || skill.id != nil {
            if skill.id == nil {
                skill.replaces = adding(identity(["skill", skill.name]), to: skill.replaces, unless: identity(["skill", component.id]))
            }
            skill.id = component.id
        }
        return skill
    }

    private static func identifiedConnector(_ component: PluginComponent) -> PluginConnector? {
        guard var connector = component.connector else { return nil }
        if component.id != PluginComponent.defaultID(forName: connector.name) || connector.id != nil {
            if connector.id == nil {
                connector.replaces = adding(
                    identity(["connector", connector.serviceType, connector.name]),
                    to: connector.replaces,
                    unless: identity(["connector", connector.serviceType, component.id])
                )
            }
            connector.id = component.id
        }
        return connector
    }

    /// A tool without an `id` is identified by its type, command and name; one
    /// that gains an `id` here also replaces that form, both with the name
    /// its `id` derives from (a version that renamed it) and with its own
    /// name (an earlier ASTRA that dropped the `id`).
    private static func identifiedTool(_ component: PluginComponent) -> PluginLocalTool? {
        guard var tool = component.tool else { return nil }
        if component.id != PluginComponent.defaultID(forName: tool.name) || tool.id != nil {
            if tool.id == nil {
                let current = identity(["tool", component.id])
                for name in [component.id, tool.name] {
                    tool.replaces = adding(identity(["tool", tool.toolType, tool.command, name]), to: tool.replaces, unless: current)
                }
            }
            tool.id = component.id
        }
        return tool
    }

    /// A component identity in `CapabilityResourceOrigin.componentID`'s form.
    private static func identity(_ parts: [String]) -> String {
        parts.map { PluginComponent.defaultID(forName: $0) }.joined(separator: ":")
    }

    private static func adding(_ identity: String, to replaces: [String]?, unless current: String) -> [String]? {
        guard identity != current, !(replaces ?? []).contains(identity) else { return replaces }
        return (replaces ?? []) + [identity]
    }

    /// `package(from:)`, refusing a manifest whose setup steps the package
    /// cannot carry. The package keeps setup only as CLI prerequisites and
    /// connector credential hints, so a declared check, verify, connect,
    /// repair or install step that does not come back out of the package
    /// unchanged would be dropped, and the plugin would read as ready without
    /// that step ever running. Such a manifest is refused instead.
    public static func checkedPackage(from manifest: PluginManifest) throws -> PluginPackage {
        // Fail closed: a later version may carry meaning this converter
        // would silently drop.
        guard manifest.manifestVersion == PluginManifest.currentVersion else {
            throw PluginManifestError.unsupportedVersion(manifest.manifestVersion)
        }
        // Every component carries exactly its kind's payload: one without it
        // would vanish in conversion, one with another's would change kind.
        for component in manifest.components where !hasExactPayload(component) {
            throw PluginManifestError.mismatchedPayload(component: component.name)
        }
        let package = package(from: manifest)
        // The package doesn't carry `worksOn`; a manifest that restricts a
        // runtime more than ASTRA's own reading of its components would lose
        // that restriction, so it is refused rather than run where it says
        // it doesn't work.
        let derived = self.manifest(from: package).worksOn
        for (runtime, declared) in manifest.worksOn.sorted(by: { $0.key < $1.key }) {
            guard let allowed = derived[runtime] else { continue }
            if rank(declared) < rank(allowed) {
                throw PluginManifestError.unenforcedRuntimeRestriction(runtime: runtime)
            }
        }
        let carried = self.manifest(from: package).components
        // The package keeps no component IDs: each comes back derived from
        // its payload (a name's slug, an MCP server's own ID). A declared ID
        // that differs would be replaced, and a later rename would then
        // change the component's identity, so it is refused instead.
        for kind in [PluginComponent.Kind.skill, .connector, .tool, .mcp, .template] {
            let derived = carried.filter { $0.kind == kind }
            for (index, component) in manifest.components.filter({ $0.kind == kind }).enumerated()
            where index >= derived.count || derived[index].id != component.id {
                throw PluginManifestError.unrepresentableComponentID(component: component.name, id: component.id)
            }
        }
        // Matched by the ID checked above (two connectors may share a name);
        // a setup step's ID isn't carried, so it is matched by its name.
        for component in manifest.components where !component.setup.isEmpty {
            let kept = carried.first {
                $0.kind == component.kind && (component.kind == .setup ? $0.name == component.name : $0.id == component.id)
            }?.setup
            guard kept == component.setup else {
                throw PluginManifestError.unrepresentableSetup(component: component.name)
            }
        }
        return package
    }

    private static func hasExactPayload(_ component: PluginComponent) -> Bool {
        let payloads: [PluginComponent.Kind: Bool] = [
            .skill: component.skill != nil,
            .connector: component.connector != nil,
            .tool: component.tool != nil,
            .mcp: component.mcp != nil,
            .template: component.template != nil
        ]
        let present = payloads.filter(\.value).map(\.key)
        if component.kind == .setup {
            // A setup step stands alone, or carries its setup requirement.
            return present.isEmpty
        }
        return present == [component.kind]
    }

    /// How much a runtime may do, least first. Full only with a recent CLI
    /// is a condition, so it ranks below unconditional `full`.
    private static func rank(_ support: PluginRuntimeSupport) -> Int {
        switch support {
        case .unsupported: 0
        case .shellOnly: 1
        case .fullWithRecentCLI: 2
        case .full: 3
        }
    }

    public static func isManifest(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["components"] != nil && object["manifestVersion"] != nil
    }

    /// Where a plugin works. On a runtime without MCP delivery, a plugin with
    /// MCP servers works through the shell relay only when it has something
    /// the relay can use (a skill, an account, a tool); an MCP-only plugin
    /// is `unsupported` there, since nothing in it reaches that runtime.
    public static func defaultWorksOn(hasMCP: Bool, hasShellComponents: Bool = true) -> [String: PluginRuntimeSupport] {
        var support: [String: PluginRuntimeSupport] = [:]
        for runtime in mcpRuntimes { support[runtime] = .full }
        for runtime in conditionalMCPRuntimes { support[runtime] = hasMCP ? .fullWithRecentCLI : .full }
        let withoutMCP: PluginRuntimeSupport = !hasMCP ? .full : (hasShellComponents ? .shellOnly : .unsupported)
        for runtime in shellOnlyRuntimes { support[runtime] = withoutMCP }
        return support
    }

    // MARK: - Setup contract

    private static func setupComponent(_ prerequisite: CLIPrerequisite) -> PluginComponent {
        let fix = prerequisite.authHint.flatMap(firstCommand)
        return PluginComponent(
            kind: .setup,
            id: slug(prerequisite.displayName),
            name: prerequisite.displayName,
            summary: prerequisite.purpose,
            setup: PluginComponentSetup(
                check: PluginSetupStep(
                    kind: .exec,
                    binary: prerequisite.binary,
                    arguments: prerequisite.livenessArgs,
                    expect: prerequisite.semantic?.rawValue,
                    context: prerequisite.contextualCheck?.rawValue
                ),
                connect: prerequisite.authHint.map { PluginSetupStep(kind: .terminal, command: fix, hint: $0) },
                repair: prerequisite.authHint.map { PluginSetupStep(kind: .terminal, command: fix, hint: $0) },
                install: PluginSetupStep(kind: .url, url: prerequisite.installURL, hint: prerequisite.installHint)
            )
        )
    }

    /// The `CLIPrerequisite.id` (binary, arguments, context) a setup
    /// component checks; nil for one that runs no CLI. Health is keyed by it,
    /// so a failure finds its own component even when two share a name.
    public static func prerequisiteID(of component: PluginComponent) -> String? {
        component.kind == .setup ? prerequisite(component)?.id : nil
    }

    private static func prerequisite(_ component: PluginComponent) -> CLIPrerequisite? {
        guard let check = component.setup.check, check.kind == .exec, let binary = check.binary else { return nil }
        return CLIPrerequisite(
            binary: binary,
            livenessArgs: check.arguments ?? ["--version"],
            semantic: check.expect.flatMap(SemanticCheck.init(rawValue:)),
            contextualCheck: check.context.flatMap(CLIContextualCheck.init(rawValue:)),
            displayName: component.name,
            purpose: component.summary,
            installURL: component.setup.install?.url,
            installHint: component.setup.install?.hint ?? "",
            authHint: component.setup.connect?.hint
        )
    }

    private static func connectorSetup(_ connector: PluginConnector) -> PluginComponentSetup {
        let fields = connector.credentialHints.map(\.key) + connector.configHints.map(\.key)
        guard !fields.isEmpty else { return PluginComponentSetup() }
        return PluginComponentSetup(
            check: connector.credentialHints.isEmpty ? nil : PluginSetupStep(kind: .credentialPresent),
            connect: PluginSetupStep(kind: .credentialForm, fields: fields),
            repair: PluginSetupStep(kind: .credentialForm, fields: fields)
        )
    }

    /// The first backticked command in a hint ("Run `gcloud auth login`." → that).
    public static func firstCommand(_ hint: String) -> String? {
        guard let start = hint.firstIndex(of: "`") else { return nil }
        let rest = hint[hint.index(after: start)...]
        guard let end = rest.firstIndex(of: "`") else { return nil }
        let command = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }

    static func slug(_ text: String) -> String {
        let pieces = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return pieces.joined(separator: "-")
    }
}
