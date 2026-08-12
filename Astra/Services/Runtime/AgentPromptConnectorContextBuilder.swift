import Foundation
import ASTRACore
import ASTRAModels

enum AgentPromptConnectorContextBuilder {
    static func section(
        from capabilityScope: TaskCapabilityPromptScope,
        task: AgentTask,
        runtime: AgentRuntimeID? = nil,
        credentialExposurePolicy: ConnectorRuntimeProjection.CredentialExposurePolicy? = nil
    ) -> PromptContextSection? {
        let exposurePolicy = credentialExposurePolicy ?? .approvedLabels(
            Set(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task))
        )
        let projection = ConnectorRuntimeProjection(
            connectors: capabilityScope.connectors,
            credentialExposurePolicy: exposurePolicy
        )
        let aliasesByID = projection.aliasesByConnectorID
        let bindingsByConnectorID = Dictionary(grouping: projection.environmentBindings(), by: \.connectorID)
        let dockerRouted = DockerWorkspaceMCPProjection.isEnabled(for: DockerExecutionPlanner.resolveEnvironment(for: task))
        let hostControlTools = Set(
            dockerRouted
                ? HostControlPlaneMCPProjection.toolNames
                : HostControlPlaneMCPProjection.requiredToolNames(capabilityScope: capabilityScope)
        )
        let usesHostControlCLIRelay = AgentRuntimeCapabilityProfile.defaultProfile(
            for: runtime ?? task.resolvedRuntimeID
        ).usesHostControlCLIRelay

        let connectorDescriptions = capabilityScope.connectors.map { conn in
            let serviceType = conn.serviceType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let hostControlTool = HostControlPlaneMCPProjection.connectorToolName(serviceType)
            let hostControlRouted = hostControlTool.map(hostControlTools.contains) == true
            return connectorDescription(
                connector: conn,
                alias: aliasesByID[conn.id] ?? ConnectorRuntimeProjection.alias(for: conn),
                bindings: bindingsByConnectorID[conn.id] ?? [],
                hostControlRouted: hostControlRouted,
                // Not gated on `hostControlRouted`: the launch environment strips a
                // brokered connector's credentials whether or not the broker tool
                // reached this runtime, so printing the env vars when it did not
                // would advertise variables the process does not have.
                brokerOwnsConnectorConfiguration: HostControlPlaneMCPProjection
                    .brokerOwnsConnectorConfiguration(serviceType),
                usesHostControlCLIRelay: usesHostControlCLIRelay
            )
        }
        guard !connectorDescriptions.isEmpty else { return nil }

        return PromptContextSection(
            kind: .tools,
            text: """
            Available Connectors (ASTRA lists only provider-visible env vars; brokered connector credentials remain inside ASTRA):
            \(connectorDescriptions.joined(separator: "\n\n"))

            The connector details and runtime routes above are authoritative for this run. Use env vars only when they are explicitly listed. When more than one connector of the same service is available, use its name or alias. If the user request is ambiguous, ask which connector to use before calling external APIs.

            \(connectorAPIGuidance(
                dockerRouted: dockerRouted,
                usesHostControlCLIRelay: usesHostControlCLIRelay
            ))
            """,
            sourcePointers: connectorSourcePointers(capabilityScope.connectors)
        )
    }

    private static func connectorDescription(
        connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        hostControlRouted: Bool,
        brokerOwnsConnectorConfiguration: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String {
        let providerBindings = brokerOwnsConnectorConfiguration ? [] : bindings
        let credentialBindings = providerBindings.filter {
            $0.kind == .credential && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let configBindings = providerBindings.filter { $0.kind == .config }
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
        if !providerBindings.isEmpty {
            let rendered = providerBindings
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
        if !brokerOwnsConnectorConfiguration, !missingCredentialKeys.isEmpty {
            desc += "\n  Credentials NOT configured (ask user to fill them in workspace settings): \(missingCredentialKeys.joined(separator: ", "))"
        }
        if brokerOwnsConnectorConfiguration, !hostControlRouted {
            // The distinction the agent otherwise gets wrong: this is a missing
            // route, not a missing credential. ASTRA holds the credential and
            // will not hand it over, so asking the user for it cannot help.
            desc += "\n  Route UNAVAILABLE in this run: this connector is reachable only through the ASTRA host-control broker. Report that the route is unavailable - do not ask for credentials and do not call the API directly."
        }
        if !configBindings.isEmpty {
            let rendered = configBindings
                .sorted { $0.envKey < $1.envKey }
                .map(\.envKey)
                .joined(separator: ", ")
            desc += "\n  Config env vars: \(rendered)"
        }
        if let example = connectorRuntimeExample(
            for: connector,
            alias: alias,
            bindings: providerBindings,
            hostControlRouted: hostControlRouted,
            usesHostControlCLIRelay: usesHostControlCLIRelay
        ) {
            desc += "\n  Runtime example: \(example)"
        }
        desc += "\n  Auth: \(connector.authMethod)"
        if !connector.notes.isEmpty { desc += "\n  Notes: \(connector.notes)" }
        return desc
    }

    private static func connectorAPIGuidance(
        dockerRouted: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String {
        if dockerRouted {
            return HostControlPlanePromptGuidance.dockerConnectorAPIGuidance
        }
        if usesHostControlCLIRelay {
            return """
            IMPORTANT: When a connector has an `astra-host-control` runtime example, invoke exactly that typed broker command through the shell. Do not use curl, raw REST, or connector credential env vars. The command is process-bound to this run and returns only broker-approved operation results.
            """
        }
        return """
        IMPORTANT: When a connector has an ASTRA host-control runtime example, use that typed broker route and do not use Bash for the connector. For other authenticated APIs, use Bash with curl/python and the listed env var tokens - NOT WebFetch. \
        WebFetch cannot handle SSO, session cookies, or token-based auth headers. Follow the per-connector runtime examples above and use only credential env vars explicitly listed in this section.
        """
    }

    private static func connectorRuntimeExample(
        for connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        hostControlRouted: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String? {
        let serviceType = connector.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch serviceType {
        case "jira":
            return jiraRuntimeExample(
                for: connector,
                alias: alias,
                bindings: bindings,
                hostControlRouted: hostControlRouted,
                usesHostControlCLIRelay: usesHostControlCLIRelay
            )
        case "redcap":
            return redcapRuntimeExample(
                alias: alias,
                bindings: bindings,
                hostControlRouted: hostControlRouted,
                usesHostControlCLIRelay: usesHostControlCLIRelay
            )
        case "gcloud", "google_cloud", "googlecloud", "gcp":
            return gcloudRuntimeExample(
                bindings: bindings,
                hostControlRouted: hostControlRouted,
                usesHostControlCLIRelay: usesHostControlCLIRelay
            )
        default:
            return nil
        }
    }

    private static func jiraRuntimeExample(
        for connector: Connector,
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        hostControlRouted: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String? {
        if hostControlRouted {
            if usesHostControlCLIRelay {
                // Each line must be independently runnable: the relay tokenizer rejects
                // `;` and every other shell metacharacter, so joining the two commands
                // into one line would make the copied example unrunnable.
                return #"astra-host-control jira --operation status --alias "\#(alias)""#
                    + "\n  Runtime example (reads): "
                    + #"astra-host-control jira --operation search-jql --alias "\#(alias)" --jql "project = KEY" --max-results 1"#
            }
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
        alias: String,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        hostControlRouted: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String? {
        if hostControlRouted {
            if usesHostControlCLIRelay {
                // One runnable command per line: the relay tokenizer rejects `;`.
                return #"astra-host-control redcap --operation status --alias "\#(alias)""#
                    + "\n  Runtime example (reads): "
                    + #"astra-host-control redcap --operation metadata --alias "\#(alias)""#
            }
            return #"mcp__astra_host__redcap with {"operation":"status","alias":"\#(alias)"}; for study structure use {"operation":"metadata","alias":"\#(alias)"}, and for subject data {"operation":"record","alias":"\#(alias)"}, which writes rows to a file in the task folder and returns the path"#
        }
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
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        hostControlRouted: Bool,
        usesHostControlCLIRelay: Bool
    ) -> String? {
        // Broker routes execute a literal argv - no shell, no `$VAR` expansion - and the
        // CLI relay tokenizer rejects `$` outright, so a routed example must carry the
        // resolved config value. These are the same values this section already prints
        // on the `Config:` line, so nothing extra is disclosed.
        let project = gcloudArgumentValue(
            matchingBinding(
                in: bindings,
                logicalNames: ["project", "gcpProject", "projectID"],
                originalKeys: ["GCP_PROJECT", "PROJECT", "PROJECT_ID"],
                keyFragments: ["PROJECT"],
                preferredKind: .config
            ),
            hostControlRouted: hostControlRouted
        )
        let region = gcloudArgumentValue(
            matchingBinding(
                in: bindings,
                logicalNames: ["region", "gcpRegion"],
                originalKeys: ["GCP_REGION", "REGION"],
                keyFragments: ["REGION"],
                preferredKind: .config
            ),
            hostControlRouted: hostControlRouted
        )

        let arguments: String
        if let project, let region {
            arguments = #"run services list --project "\#(project)" --region "\#(region)" --format=json"#
        } else if let project {
            arguments = #"projects describe "\#(project)" --format=json"#
        } else if let region {
            arguments = #"run services list --region "\#(region)" --format=json"#
        } else {
            return nil
        }
        if hostControlRouted {
            if usesHostControlCLIRelay {
                return "astra-host-control gcloud -- \(arguments)"
            }
            return "mcp__astra_host__gcloud with an arguments array equivalent to: \(arguments)"
        }
        return "gcloud \(arguments)"
    }

    /// Env-var token for direct shell use, resolved literal for broker-routed examples.
    private static func gcloudArgumentValue(
        _ binding: ConnectorRuntimeProjection.EnvironmentBinding?,
        hostControlRouted: Bool
    ) -> String? {
        guard let binding else { return nil }
        guard hostControlRouted else { return "$\(binding.envKey)" }
        let literal = binding.value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A value carrying shell metacharacters would be rejected by the relay tokenizer,
        // so drop it rather than emit an example the agent cannot run.
        guard !literal.isEmpty,
              literal.rangeOfCharacter(from: hostControlRelayUnsafeCharacters) == nil else {
            return nil
        }
        return literal
    }

    private static let hostControlRelayUnsafeCharacters = CharacterSet(
        charactersIn: ";&|<>\n\r`$(){}~*?[]#!\"'\\"
    )

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
