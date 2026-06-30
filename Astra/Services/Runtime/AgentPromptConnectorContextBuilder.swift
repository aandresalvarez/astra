import Foundation

enum AgentPromptConnectorContextBuilder {
    static func section(
        from capabilityScope: TaskCapabilityPromptScope,
        task: AgentTask
    ) -> PromptContextSection? {
        let projection = ConnectorRuntimeProjection(connectors: capabilityScope.connectors)
        let aliasesByID = projection.aliasesByConnectorID
        let bindingsByConnectorID = Dictionary(grouping: projection.environmentBindings(), by: \.connectorID)
        let dockerRouted = DockerWorkspaceMCPProjection.isEnabled(for: DockerExecutionPlanner.resolveEnvironment(for: task))

        let connectorDescriptions = capabilityScope.connectors.map { conn in
            connectorDescription(
                connector: conn,
                alias: aliasesByID[conn.id] ?? ConnectorRuntimeProjection.alias(for: conn),
                bindings: bindingsByConnectorID[conn.id] ?? [],
                dockerRouted: dockerRouted
            )
        }
        guard !connectorDescriptions.isEmpty else { return nil }

        return PromptContextSection(
            kind: .tools,
            text: """
            Available Connectors (credentials are pre-loaded into your process environment - use them directly, never ask the user to provide them again):
            \(connectorDescriptions.joined(separator: "\n\n"))

            The connector env vars listed above and the ASTRA_CONNECTORS JSON manifest are authoritative for this run. When more than one connector of the same service is available, use the connector name or alias to pick the right env vars. If behavioral instructions mention bare legacy env names, use those names only when they are explicitly listed above or in ASTRA_CONNECTORS. If the user request is ambiguous, ask which connector to use before calling external APIs.

            \(connectorAPIGuidance(dockerRouted: dockerRouted))
            """,
            sourcePointers: connectorSourcePointers(capabilityScope.connectors)
        )
    }

    private static func connectorDescription(
        connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        dockerRouted: Bool
    ) -> String {
        let credentialBindings = bindings.filter {
            $0.kind == .credential && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let configBindings = bindings.filter { $0.kind == .config }
        let configuredCredentialKeys = Set(credentialBindings.map(\.originalKey))
        let missingCredentialKeys = connector.credentialKeys.filter { !configuredCredentialKeys.contains($0) }

        var desc = "[\(connector.name)] \(connector.serviceType) - \(connector.connectorDescription)"
        desc += "\n  Alias: \(alias)"
        if !connector.baseURL.isEmpty { desc += "\n  Base URL: \(connector.baseURL)" }
        if !configBindings.isEmpty {
            let configs = configBindings
                .sorted { $0.envKey < $1.envKey }
                .map { "\($0.originalKey): \($0.value)" }
                .joined(separator: ", ")
            desc += "\n  Config: \(configs)"
        }
        if !bindings.isEmpty {
            let rendered = bindings
                .sorted { $0.envKey < $1.envKey }
                .map { "\($0.logicalName): $\($0.envKey)" }
                .joined(separator: ", ")
            desc += "\n  Connector env vars: \(rendered)"
        }
        if !credentialBindings.isEmpty {
            let rendered = credentialBindings
                .sorted { $0.envKey < $1.envKey }
                .map(\.envKey)
                .joined(separator: ", ")
            desc += "\n  Credentials ALREADY SET in your environment: \(rendered) - use os.environ[\"KEY\"] directly, do NOT ask the user for these"
        }
        if !missingCredentialKeys.isEmpty {
            desc += "\n  Credentials NOT configured (ask user to fill them in workspace settings): \(missingCredentialKeys.joined(separator: ", "))"
        }
        if !configBindings.isEmpty {
            let rendered = configBindings
                .sorted { $0.envKey < $1.envKey }
                .map(\.envKey)
                .joined(separator: ", ")
            desc += "\n  Config env vars: \(rendered)"
        }
        if let example = connectorRuntimeExample(for: connector, alias: alias, bindings: bindings, dockerRouted: dockerRouted) {
            desc += "\n  Runtime example: \(example)"
        }
        desc += "\n  Auth: \(connector.authMethod)"
        if !connector.notes.isEmpty { desc += "\n  Notes: \(connector.notes)" }
        return desc
    }

    private static func connectorAPIGuidance(dockerRouted: Bool) -> String {
        if dockerRouted {
            return """
            IMPORTANT: This task is routed through a Docker workspace executor. Do not use native host Bash or Docker workspace_shell for host connector APIs. For Jira, use `mcp__astra_host__jira` (or Copilot's `astra_host-jira`) with the projected ASTRA_CONNECTORS credentials. For Google Cloud or BigQuery host CLI operations, use `mcp__astra_host__gcloud` or `mcp__astra_host__bq`. Use workspace_shell only for project commands that belong inside the container image. WebFetch cannot handle SSO, session cookies, or token-based auth headers.
            """
        }
        return """
        IMPORTANT: To call authenticated APIs, use Bash with curl/python and the env var tokens - NOT WebFetch. \
        WebFetch cannot handle SSO, session cookies, or token-based auth headers. Prefer the per-connector runtime examples above, or in Python use os.environ["ENV_KEY_LISTED_ABOVE"] to read the credential.
        """
    }

    private static func connectorRuntimeExample(
        for connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        dockerRouted: Bool
    ) -> String? {
        let serviceType = connector.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch serviceType {
        case "jira":
            return jiraRuntimeExample(for: connector, alias: alias, bindings: bindings, dockerRouted: dockerRouted)
        case "redcap":
            return redcapRuntimeExample(bindings: bindings)
        case "gcloud", "google_cloud", "googlecloud", "gcp":
            return gcloudRuntimeExample(bindings: bindings)
        default:
            return nil
        }
    }

    private static func jiraRuntimeExample(
        for connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        dockerRouted: Bool
    ) -> String? {
        if dockerRouted {
            return #"mcp__astra_host__jira with {"operation":"status","alias":"\#(alias)"}; for reads use {"operation":"search_jql","alias":"\#(alias)","jql":"project = KEY","max_results":1}"#
        }
        guard let baseURL = runtimeURLBase(
            bindings: bindings,
            logicalNames: ["baseURL", "jiraBaseURL", "url"],
            originalKeys: ["JIRA_BASE_URL", "BASE_URL", "URL"],
            keyFragments: ["BASE_URL"]
        ) else {
            return nil
        }
        guard let email = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["email", "jiraEmail", "username"],
            originalKeys: ["JIRA_EMAIL", "EMAIL", "USERNAME"],
            keyFragments: ["EMAIL", "USERNAME"],
            preferredKind: .credential
        ),
              let token = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["apiToken", "token", "jiraAPIToken"],
            originalKeys: ["JIRA_API_TOKEN", "API_TOKEN", "TOKEN"],
            keyFragments: ["API_TOKEN", "TOKEN"],
            preferredKind: .credential
        ) else {
            return nil
        }
        let url = shellQuote("\(baseURL)/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS")
        return #"curl -s -u "\#(email):\#(token)" -H "Content-Type: application/json" "\#(url)""#
    }

    private static func redcapRuntimeExample(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        guard let url = runtimeURLBase(
            bindings: bindings,
            logicalNames: ["apiURL", "baseURL", "url"],
            originalKeys: ["REDCAP_API_URL", "API_URL", "BASE_URL", "URL"],
            keyFragments: ["API_URL", "BASE_URL"]
        ) else {
            return nil
        }
        guard let token = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["apiToken", "token", "redcapAPIToken"],
            originalKeys: ["REDCAP_API_TOKEN", "API_TOKEN", "TOKEN"],
            keyFragments: ["API_TOKEN", "TOKEN"],
            preferredKind: .credential
        ) else {
            return nil
        }
        let quotedURL = shellQuote(url)
        return #"curl -sS -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" -X POST --data-urlencode "token=\#(token)" --data-urlencode "content=project" --data-urlencode "format=json" --data-urlencode "returnFormat=json" "\#(quotedURL)""#
    }

    private static func gcloudRuntimeExample(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        let project = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["project", "gcpProject", "projectID"],
            originalKeys: ["GCP_PROJECT", "PROJECT", "PROJECT_ID"],
            keyFragments: ["PROJECT"],
            preferredKind: .config
        )
        let region = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["region", "gcpRegion"],
            originalKeys: ["GCP_REGION", "REGION"],
            keyFragments: ["REGION"],
            preferredKind: .config
        )

        if let project, let region {
            return #"gcloud run services list --project "\#(project)" --region "\#(region)" --format=json"#
        } else if let project {
            return #"gcloud projects describe "\#(project)" --format=json"#
        } else if let region {
            return #"gcloud run services list --region "\#(region)" --format=json"#
        }
        return nil
    }

    private static func runtimeEnvValue(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String],
        preferredKind: ConnectorRuntimeProjection.BindingKind
    ) -> String? {
        guard let binding = matchingBinding(
            in: bindings,
            logicalNames: logicalNames,
            originalKeys: originalKeys,
            keyFragments: keyFragments,
            preferredKind: preferredKind
        ) else {
            return nil
        }
        return "$\(binding.envKey)"
    }

    private static func runtimeURLBase(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String]
    ) -> String? {
        if let binding = matchingBinding(
            in: bindings,
            logicalNames: logicalNames,
            originalKeys: originalKeys,
            keyFragments: keyFragments,
            preferredKind: .config
        ) {
            return "${\(binding.envKey)}"
        }
        return nil
    }

    private static func matchingBinding(
        in bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String],
        preferredKind: ConnectorRuntimeProjection.BindingKind
    ) -> ConnectorRuntimeProjection.EnvironmentBinding? {
        let preferred = bindings.filter { $0.kind == preferredKind }
        return firstMatchingBinding(in: preferred, logicalNames: logicalNames, originalKeys: originalKeys, keyFragments: keyFragments)
            ?? firstMatchingBinding(in: bindings, logicalNames: logicalNames, originalKeys: originalKeys, keyFragments: keyFragments)
    }

    private static func firstMatchingBinding(
        in bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String]
    ) -> ConnectorRuntimeProjection.EnvironmentBinding? {
        let normalizedLogicalNames = Set(logicalNames.map { $0.lowercased() })
        let normalizedOriginalKeys = Set(originalKeys.map { $0.uppercased() })
        let normalizedFragments = keyFragments.map { $0.uppercased() }
        return bindings
            .sorted { $0.envKey < $1.envKey }
            .first { binding in
                let logicalName = binding.logicalName.lowercased()
                let originalKey = binding.originalKey.uppercased()
                return normalizedLogicalNames.contains(logicalName)
                    || normalizedOriginalKeys.contains(originalKey)
                    || normalizedFragments.contains { originalKey.contains($0) }
            }
    }

    private static func shellQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func connectorSourcePointers(_ connectors: [Connector]) -> [PromptContextSourcePointer] {
        connectors.map { connector in
            PromptContextSourcePointer(label: "connector \(connector.name)", target: "\(connector.serviceType) \(connector.id.uuidString)")
        } + [PromptContextSourcePointer(label: "connector runtime manifest", target: "ASTRA_CONNECTORS environment")]
    }
}
