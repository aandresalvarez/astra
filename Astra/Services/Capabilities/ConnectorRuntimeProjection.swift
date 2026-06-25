import Foundation
import ASTRACore

struct ConnectorRuntimeProjection {
    struct Manifest: Codable, Equatable {
        var connectors: [ManifestConnector]
    }

    struct ManifestConnector: Codable, Equatable {
        var id: String
        var alias: String
        var envPrefix: String
        var name: String
        var serviceType: String
        var baseURL: String
        var authMethod: String
        var env: [String: String]
        var credentials: [String: String]
        var config: [String: String]
    }

    enum BindingKind: String, Equatable {
        case credential
        case config
    }

    struct EnvironmentBinding: Equatable {
        var connectorID: UUID
        var alias: String
        var logicalName: String
        var originalKey: String
        var envKey: String
        var value: String
        var kind: BindingKind
    }

    private let connectors: [Connector]
    private let secretStore: SecretStore

    init(connectors: [Connector], secretStore: SecretStore = KeychainSecretStore()) {
        self.connectors = connectors
        self.secretStore = secretStore
    }

    var aliasesByConnectorID: [UUID: String] {
        Self.aliasesByConnectorID(for: connectors)
    }

    func environmentVariables(includeLegacySingleConnectorFallback: Bool = false) -> [String: String] {
        guard !connectors.isEmpty else { return [:] }
        let aliases = aliasesByConnectorID
        let bindings = environmentBindings(aliases: aliases)
        let serviceTypesByConnectorID = normalizedServiceTypesByConnectorID()
        let serviceCounts = serviceTypesByConnectorID.values.reduce(into: [:]) { counts, serviceType in
            counts[serviceType, default: 0] += 1
        }
        let legacyKeyCounts = bindings.reduce(into: [:]) { counts, binding in
            counts[binding.originalKey, default: 0] += 1
        }
        var output: [String: String] = [:]
        var injectedLegacyKeys: [String] = []

        for binding in bindings {
            output[binding.envKey] = binding.value
            guard includeLegacySingleConnectorFallback,
                  serviceCounts[serviceTypesByConnectorID[binding.connectorID] ?? ""] == 1,
                  legacyKeyCounts[binding.originalKey] == 1,
                  Self.isSafeLegacyEnvName(binding.originalKey) else {
                continue
            }
            output[binding.originalKey] = binding.value
            injectedLegacyKeys.append(binding.originalKey)
        }

        if !injectedLegacyKeys.isEmpty {
            // Deprecation telemetry: bare key names silently rebind when a
            // second connector of the same service appears. The fallback is
            // scheduled for removal once these audits go quiet.
            AppLogger.audit(.connectorTested, category: "Capabilities", fields: [
                "source": "connector_env_projection",
                "result": "legacy_bare_env_fallback_injected",
                "legacy_key_count": String(injectedLegacyKeys.count),
                "legacy_key_names": injectedLegacyKeys.sorted().joined(separator: ",")
            ], level: .info)
        }

        output["ASTRA_CONNECTORS"] = manifestJSON(aliases: aliases)
        return output
    }

    /// Declared credential keys that fail to load a non-empty value from
    /// the secret store, per connector. Key names only — never values.
    func missingCredentialKeysByConnector() -> [(connector: Connector, missingKeys: [String])] {
        connectors.compactMap { connector in
            let credentials = connector.credentials(store: secretStore)
            let missing = connector.credentialKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { key in
                    guard !key.isEmpty else { return false }
                    let value = credentials[key] ?? ""
                    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            return missing.isEmpty ? nil : (connector, missing)
        }
    }

    func manifest() -> Manifest {
        let aliases = aliasesByConnectorID
        return Manifest(connectors: connectors.map { connector in
            manifestConnector(for: connector, alias: aliases[connector.id] ?? Self.alias(for: connector))
        })
    }

    func manifestJSON() -> String {
        manifestJSON(aliases: aliasesByConnectorID)
    }

    func environmentBindings() -> [EnvironmentBinding] {
        environmentBindings(aliases: aliasesByConnectorID)
    }

    static func alias(for connector: Connector) -> String {
        aliasBase(for: connector)
    }

    static func aliasesByConnectorID(for connectors: [Connector]) -> [UUID: String] {
        var aliases: [UUID: String] = [:]
        let connectorsByService = Dictionary(grouping: connectors, by: serviceAliasScope(for:))

        for scopedConnectors in connectorsByService.values {
            var usedAliases = Set<String>()
            let connectorsByBase = Dictionary(grouping: scopedConnectors, by: aliasBase(for:))
            let preferences = scopedConnectors.map { connector in
                let base = aliasBase(for: connector)
                let hasDuplicateBase = (connectorsByBase[base]?.count ?? 0) > 1
                return AliasPreference(
                    connector: connector,
                    preferred: hasDuplicateBase ? "\(base)_\(shortID(connector.id))" : base,
                    generatedForDuplicateBase: hasDuplicateBase
                )
            }
            .sorted { lhs, rhs in
                if lhs.preferred != rhs.preferred { return lhs.preferred < rhs.preferred }
                if lhs.generatedForDuplicateBase != rhs.generatedForDuplicateBase {
                    return !lhs.generatedForDuplicateBase
                }
                return stableID(lhs.connector.id) < stableID(rhs.connector.id)
            }

            for preference in preferences {
                aliases[preference.connector.id] = uniqueAlias(
                    startingWith: preference.preferred,
                    usedAliases: &usedAliases
                )
            }
        }

        return aliases
    }

    static func envPrefix(for connector: Connector, alias: String? = nil) -> String {
        let service = envToken(connector.serviceType)
        let aliasToken = envToken(alias ?? Self.alias(for: connector))
        if service.isEmpty { return aliasToken.isEmpty ? "CONNECTOR" : aliasToken }
        if aliasToken.isEmpty { return service }
        return "\(service)_\(aliasToken)"
    }

    private func manifestJSON(aliases: [UUID: String]) -> String {
        let manifest = Manifest(connectors: connectors.map { connector in
            manifestConnector(for: connector, alias: aliases[connector.id] ?? Self.alias(for: connector))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"connectors":[]}"#
        }
        return json
    }

    private func manifestConnector(for connector: Connector, alias: String) -> ManifestConnector {
        let bindings = environmentBindings(for: connector, alias: alias)
        let env = Dictionary(
            bindings.map { ($0.logicalName, $0.envKey) },
            uniquingKeysWith: { _, last in last }
        )
        let credentials = Dictionary(
            bindings.filter { $0.kind == .credential }.map { ($0.logicalName, $0.envKey) },
            uniquingKeysWith: { _, last in last }
        )
        let config = Dictionary(
            bindings.filter { $0.kind == .config }.map { ($0.logicalName, $0.envKey) },
            uniquingKeysWith: { _, last in last }
        )

        return ManifestConnector(
            id: connector.id.uuidString,
            alias: alias,
            envPrefix: Self.envPrefix(for: connector, alias: alias),
            name: connector.name,
            serviceType: connector.serviceType,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            env: env,
            credentials: credentials,
            config: config
        )
    }

    private func environmentBindings(aliases: [UUID: String]) -> [EnvironmentBinding] {
        connectors.flatMap { connector in
            environmentBindings(for: connector, alias: aliases[connector.id] ?? Self.alias(for: connector))
        }
    }

    private func environmentBindings(for connector: Connector, alias: String) -> [EnvironmentBinding] {
        var bindings: [EnvironmentBinding] = []
        let prefix = Self.envPrefix(for: connector, alias: alias)
        var usedEnvKeys = Set<String>()
        var usedLogicalNames = Set<String>()
        let credentials = connector.credentials(store: secretStore)

        for key in connector.credentialKeys {
            let originalKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalKey.isEmpty,
                  let value = credentials[key] ?? credentials[originalKey],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            Self.appendBinding(
                connector: connector,
                alias: alias,
                prefix: prefix,
                originalKey: originalKey,
                value: value,
                kind: .credential,
                usedEnvKeys: &usedEnvKeys,
                usedLogicalNames: &usedLogicalNames,
                to: &bindings
            )
        }

        for (key, value) in zip(connector.configKeys, connector.configValues) {
            let originalKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalKey.isEmpty,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            Self.appendBinding(
                connector: connector,
                alias: alias,
                prefix: prefix,
                originalKey: originalKey,
                value: value,
                kind: .config,
                usedEnvKeys: &usedEnvKeys,
                usedLogicalNames: &usedLogicalNames,
                to: &bindings
            )
        }

        return bindings
    }

    private static func appendBinding(
        connector: Connector,
        alias: String,
        prefix: String,
        originalKey: String,
        value: String,
        kind: BindingKind,
        usedEnvKeys: inout Set<String>,
        usedLogicalNames: inout Set<String>,
        to bindings: inout [EnvironmentBinding]
    ) {
        let suffix = logicalEnvSuffix(for: originalKey, connector: connector)
        let envKey = uniqueRuntimeName(startingWith: "\(prefix)_\(suffix)", usedNames: &usedEnvKeys)
        let logicalName = uniqueManifestName(
            startingWith: manifestLogicalName(for: suffix),
            usedNames: &usedLogicalNames
        )
        bindings.append(EnvironmentBinding(
            connectorID: connector.id,
            alias: alias,
            logicalName: logicalName,
            originalKey: originalKey,
            envKey: envKey,
            value: value,
            kind: kind
        ))
    }

    /// The bare legacy fallback exports connector key names verbatim into
    /// the task environment. Key names are package/user-controlled, so
    /// process-critical and loader variables must never be claimable —
    /// a connector config key literally named PATH would otherwise poison
    /// every launch. The prefixed projected names are always safe.
    static func isSafeLegacyEnvName(_ name: String) -> Bool {
        let critical: Set<String> = [
            "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR",
            "SSH_AUTH_SOCK", "XPC_SERVICE_NAME"
        ]
        if critical.contains(name) { return false }
        for prefix in ["DYLD_", "LD_", "ASTRA_"] where name.hasPrefix(prefix) {
            return false
        }
        return true
    }

    private func normalizedServiceTypesByConnectorID() -> [UUID: String] {
        connectors.reduce(into: [:]) { counts, connector in
            counts[connector.id] = Self.normalizedServiceType(connector.serviceType)
        }
    }

    private static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func aliasBase(for connector: Connector) -> String {
        let preferred = slug(connector.name)
        let fallback = slug(connector.serviceType)
        let alias = preferred.isEmpty ? fallback : preferred
        let normalized = alias.isEmpty ? "connector" : alias
        if normalized.first?.isLetter == true {
            return String(normalized.prefix(48))
        }
        return String("c_\(normalized)".prefix(48))
    }

    private static func uniqueAlias(startingWith preferred: String, usedAliases: inout Set<String>) -> String {
        if usedAliases.insert(preferred).inserted { return preferred }
        var index = 2
        while true {
            let candidate = "\(preferred)_\(index)"
            if usedAliases.insert(candidate).inserted { return candidate }
            index += 1
        }
    }

    private static func uniqueRuntimeName(startingWith preferred: String, usedNames: inout Set<String>) -> String {
        if usedNames.insert(preferred).inserted { return preferred }
        var index = 2
        while true {
            let candidate = "\(preferred)_\(index)"
            if usedNames.insert(candidate).inserted { return candidate }
            index += 1
        }
    }

    private static func uniqueManifestName(startingWith preferred: String, usedNames: inout Set<String>) -> String {
        if usedNames.insert(preferred).inserted { return preferred }
        var index = 2
        while true {
            let candidate = "\(preferred)\(index)"
            if usedNames.insert(candidate).inserted { return candidate }
            index += 1
        }
    }

    private static func shortID(_ id: UUID) -> String {
        id.uuidString.prefix(8).lowercased()
    }

    private static func stableID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private struct AliasPreference {
        var connector: Connector
        var preferred: String
        var generatedForDuplicateBase: Bool
    }

    private static func slug(_ value: String) -> String {
        var output = ""
        var previousWasSeparator = false

        for scalar in value.lowercased().unicodeScalars {
            if isASCIIAlphanumeric(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("_")
                previousWasSeparator = true
            }
        }

        return output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func envToken(_ value: String) -> String {
        let slugged = slug(value)
        guard !slugged.isEmpty else { return "" }
        return slugged.uppercased()
    }

    private static func serviceAliasScope(for connector: Connector) -> String {
        let service = envToken(connector.serviceType)
        return service.isEmpty ? "CONNECTOR" : service
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(Int(scalar.value)) ||
            (97...122).contains(Int(scalar.value))
    }

    private static func logicalEnvSuffix(for key: String, connector: Connector) -> String {
        let rawKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let candidates = [
            envToken(connector.serviceType),
            envToken(connector.name)
        ].filter { !$0.isEmpty }

        for candidate in candidates where rawKey.hasPrefix(candidate + "_") {
            let suffix = rawKey.dropFirst(candidate.count + 1)
            if !suffix.isEmpty { return String(suffix) }
        }

        return rawKey
    }

    private static func manifestLogicalName(for suffix: String) -> String {
        let parts = suffix
            .split(separator: "_")
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "value" }
        return parts.dropFirst().reduce(first) { partial, next in
            partial + manifestWord(next)
        }
    }

    private static func manifestWord(_ value: String) -> String {
        switch value {
        case "api": return "API"
        case "id": return "ID"
        case "url", "uri": return value.uppercased()
        default:
            guard let first = value.first else { return "" }
            return first.uppercased() + String(value.dropFirst())
        }
    }
}
