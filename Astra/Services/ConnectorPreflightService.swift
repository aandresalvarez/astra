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

    static func requiresPreflight(_ connector: Connector) -> Bool {
        triggerKeywordsByServiceType.keys.contains(connector.serviceType.lowercased())
    }

    static func connectorsRequiringPreflight(
        from connectors: [Connector],
        contextText: String
    ) -> [Connector] {
        let normalizedText = contextText.lowercased()
        return connectors.filter { connector in
            let serviceType = connector.serviceType.lowercased()
            guard let keywords = triggerKeywordsByServiceType[serviceType] else { return false }
            let connectorName = connector.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return keywords.contains { normalizedText.contains($0) }
                || (!connectorName.isEmpty && normalizedText.contains(connectorName))
        }
    }

    static func firstBlockingIssue(
        connectors: [Connector],
        store: SecretStore = KeychainSecretStore(),
        transport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport(),
        contextText: String = ""
    ) async -> ConnectorPreflightIssue? {
        for connector in connectors where requiresPreflight(connector) {
            let scopedConnector = connector.scopedForPreflight(contextText: contextText)
            let result = await scopedConnector.testConnection(store: store, transport: transport)
            guard !result.0 else { continue }
            return ConnectorPreflightIssue(
                connectorID: connector.id,
                connectorName: connector.name,
                serviceType: connector.serviceType,
                message: result.1
            )
        }
        return nil
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
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init))
        return configuredProjects.filter { words.contains($0) }
    }

    static func projectKeys(from raw: String) -> [String] {
        raw.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }
}
