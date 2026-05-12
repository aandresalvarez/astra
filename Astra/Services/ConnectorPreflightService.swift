import Foundation
import ASTRACore

struct ConnectorPreflightIssue {
    let connectorID: UUID
    let connectorName: String
    let serviceType: String
    let message: String

    var auditFields: [String: String] {
        [
            "connector_id": connectorID.uuidString,
            "connector_name": connectorName,
            "service_type": serviceType,
            "result": "preflight_failed"
        ]
    }
}

enum ConnectorPreflightService {
    private static let triggerKeywordsByServiceType: [String: [String]] = [
        "jira": ["jira", "atlassian"]
    ]

    static func preferredRuntimeConnectors(
        from connectors: [Connector],
        contextText: String,
        store: SecretStore = KeychainSecretStore()
    ) -> [Connector] {
        var grouped: [String: [Connector]] = [:]
        var serviceOrder: [String] = []
        for connector in connectors {
            let serviceType = normalizedServiceType(connector.serviceType)
            if grouped[serviceType] == nil {
                grouped[serviceType] = []
                serviceOrder.append(serviceType)
            }
            grouped[serviceType]?.append(connector)
        }

        return serviceOrder.flatMap { serviceType -> [Connector] in
            let connectors = grouped[serviceType] ?? []
            guard triggerKeywordsByServiceType[serviceType] != nil else {
                return connectors
            }
            return rankedConnectorsForService(connectors, contextText: contextText, store: store)
        }
    }

    static func requiresPreflight(_ connector: Connector) -> Bool {
        triggerKeywordsByServiceType.keys.contains(connector.serviceType.lowercased())
    }

    static func connectorsRequiringPreflight(
        from connectors: [Connector],
        contextText: String,
        store: SecretStore = KeychainSecretStore()
    ) -> [Connector] {
        let normalizedText = contextText.lowercased()
        let matches = connectors.filter { connector in
            let serviceType = connector.serviceType.lowercased()
            guard let keywords = triggerKeywordsByServiceType[serviceType] else { return false }
            let connectorName = connector.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return keywords.contains { normalizedText.contains($0) }
                || (!connectorName.isEmpty && normalizedText.contains(connectorName))
        }
        return rankedPreflightConnectors(matches, contextText: contextText, store: store)
    }

    static func firstBlockingIssue(
        connectors: [Connector],
        store: SecretStore = KeychainSecretStore(),
        transport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport(),
        contextText: String = "",
        workspaceID: UUID? = nil,
        traceID: String? = nil
    ) async -> ConnectorPreflightIssue? {
        let candidates = rankedPreflightConnectors(
            connectors.filter(requiresPreflight),
            contextText: contextText,
            store: store
        )
        var firstIssue: ConnectorPreflightIssue?
        for connector in candidates {
            let scopedConnector = connector.scopedForPreflight(contextText: contextText)
            let result = await scopedConnector.testConnection(
                store: store,
                transport: transport,
                source: "task_preflight",
                workspaceID: workspaceID ?? connector.workspace?.id,
                traceID: traceID
            )
            if result.0 {
                return nil
            }
            if firstIssue == nil {
                firstIssue = ConnectorPreflightIssue(
                    connectorID: connector.id,
                    connectorName: connector.name,
                    serviceType: connector.serviceType,
                    message: result.1
                )
            }
        }
        return firstIssue
    }

    private static func rankedPreflightConnectors(
        _ connectors: [Connector],
        contextText: String,
        store: SecretStore
    ) -> [Connector] {
        preferredRuntimeConnectors(
            from: connectors,
            contextText: contextText,
            store: store
        ).filter(requiresPreflight)
    }

    private static func rankedConnectorsForService(
        _ connectors: [Connector],
        contextText: String,
        store: SecretStore
    ) -> [Connector] {
        let ranked = connectors.sorted { lhs, rhs in
            preflightScore(lhs, contextText: contextText, store: store)
                > preflightScore(rhs, contextText: contextText, store: store)
        }
        let runnable = ranked.filter { isRunnableCandidate($0, store: store) }
        return runnable.isEmpty ? ranked : runnable
    }

    private static func preflightScore(
        _ connector: Connector,
        contextText: String,
        store: SecretStore
    ) -> Int {
        var score = 0

        if isRunnableCandidate(connector, store: store) {
            score += 1_000
        }
        if connector.isGlobal {
            score += 25
        }
        if !isPlaceholderBaseURL(connector.baseURL) {
            score += 20
        }

        if normalizedServiceType(connector.serviceType) == "jira" {
            let configuredProjects = Connector.projectKeys(from: connector.config["JIRA_PROJECTS"] ?? "")
            let requestedProjects = Connector.projectKeysMentioned(in: contextText, configuredProjects: configuredProjects)
            if !requestedProjects.isEmpty {
                score += 500
            } else if !configuredProjects.isEmpty {
                score += 50
            }
        }

        return score
    }

    private static func isRunnableCandidate(_ connector: Connector, store: SecretStore) -> Bool {
        if connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if isPlaceholderBaseURL(connector.baseURL) {
            return false
        }
        if connector.authMethod != "none" {
            if connector.credentialKeys.isEmpty {
                return false
            }
            if !connector.missingCredentialKeys(store: store).isEmpty {
                return false
            }
        }
        return true
    }

    private static func isPlaceholderBaseURL(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized.contains("yourcompany.")
            || normalized.contains("example.")
    }

    private static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension Connector {
    func scopedForPreflight(contextText: String) -> Connector {
        guard serviceType.caseInsensitiveCompare("jira") == .orderedSame else { return self }
        let configuredProjects = Self.projectKeys(from: config["JIRA_PROJECTS"] ?? "")
        guard !configuredProjects.isEmpty else { return self }

        let requestedProjects = Self.projectKeysMentioned(in: contextText, configuredProjects: configuredProjects)
        guard !requestedProjects.isEmpty, requestedProjects.count < configuredProjects.count else {
            return self
        }

        let scoped = Connector(
            name: name,
            serviceType: serviceType,
            icon: icon,
            connectorDescription: connectorDescription,
            baseURL: baseURL,
            authMethod: authMethod
        )
        scoped.id = id
        scoped.credentialKeys = credentialKeys
        scoped.credentialValues = credentialValues
        scoped.configKeys = configKeys
        scoped.configValues = configValues
        if let index = scoped.configKeys.firstIndex(of: "JIRA_PROJECTS") {
            scoped.configValues[index] = requestedProjects.joined(separator: ",")
        } else {
            scoped.configKeys.append("JIRA_PROJECTS")
            scoped.configValues.append(requestedProjects.joined(separator: ","))
        }
        scoped.isGlobal = isGlobal
        scoped.testHTTPMethod = testHTTPMethod
        scoped.notes = notes
        return scoped
    }

    static func projectKeysMentioned(in text: String, configuredProjects: [String]) -> [String] {
        let words = Set(text
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init))
        return configuredProjects.filter { words.contains($0) }
    }

    static func projectKeys(from raw: String) -> [String] {
        raw.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }
}
