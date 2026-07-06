import Foundation
import SwiftData
import ASTRACore

@Model
public final class Connector {
    public var id: UUID
    public var name: String
    public var serviceType: String  // "jira", "slack", "github", "database", "rest_api", "custom"
    public var icon: String
    public var connectorDescription: String

    // Connection
    public var baseURL: String
    public var authMethod: String  // "basic", "bearer", "api_key", "none"

    // Credentials (keys stored here, values in Keychain)
    public var credentialKeys: [String]
    // Legacy: kept for migration. New credentials go to Keychain only.
    public var credentialValues: [String]

    // Configuration (non-secret — visible in UI, e.g. projects, repos)
    public var configKeys: [String]
    public var configValues: [String]

    public var isGlobal: Bool = false
    public var testHTTPMethod: String = "GET"
    public var notes: String
    public var originPackageID: String?
    public var originPackageVersion: String?
    public var originComponentID: String?
    public var originComponentKind: String?
    public var originSourceKind: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var skill: Skill?
    public var workspace: Workspace?

    public init(
        name: String = "",
        serviceType: String = "custom",
        icon: String = "network",
        connectorDescription: String = "",
        baseURL: String = "",
        authMethod: String = "none"
    ) {
        self.id = UUID()
        self.name = name
        self.serviceType = serviceType
        self.icon = icon
        self.connectorDescription = connectorDescription
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.credentialKeys = []
        self.credentialValues = []
        self.configKeys = []
        self.configValues = []
        self.notes = ""
        self.originPackageID = nil
        self.originPackageVersion = nil
        self.originComponentID = nil
        self.originComponentKind = nil
        self.originSourceKind = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Computed

    private var secretFacts: ConnectorSecretFacts {
        ConnectorSecretFacts(
            id: id,
            name: name,
            serviceType: serviceType,
            baseURL: baseURL,
            originPackageID: originPackageID,
            originComponentID: originComponentID
        )
    }

    /// Load credentials from Keychain. Legacy plaintext values are migrated at app launch.
    public var credentials: [String: String] {
        credentials(store: SecretStoreSeam.required)
    }

    public func credentials(store: SecretStore) -> [String: String] {
        ConnectorSecretSeam.required.loadAllCredentials(keys: credentialKeys, facts: secretFacts, store: store)
    }

    public func missingCredentialKeys(store: SecretStore = SecretStoreSeam.required) -> [String] {
        let resolved = credentials(store: store)
        return credentialKeys.filter { key in
            let value = resolved[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
        }
    }

    public var config: [String: String] {
        Dictionary(zip(configKeys, configValues), uniquingKeysWith: { _, last in last })
    }

    /// All key-value pairs merged (for passing as env vars to the process)
    public var allEnvironmentVariables: [String: String] {
        var merged = credentials
        for (k, v) in config { merged[k] = v }
        return merged
    }

    /// Save a credential value to Keychain and keep the key in SwiftData.
    public func saveCredential(key: String, value: String) {
        let upperKey = key.uppercased()
        ConnectorSecretSeam.required.saveCredential(value, key: upperKey, facts: secretFacts)
        if let index = credentialKeys.firstIndex(where: { $0.caseInsensitiveCompare(upperKey) == .orderedSame }) {
            credentialKeys[index] = upperKey
            if index < credentialValues.count {
                credentialValues[index] = ""
            }
        } else {
            credentialKeys.append(upperKey)
            credentialValues.append("")
        }
        updatedAt = Date()
    }

    /// Remove a credential from both Keychain and SwiftData.
    public func removeCredential(at index: Int) {
        guard index < credentialKeys.count else { return }
        let key = credentialKeys[index]
        ConnectorSecretSeam.required.deleteCredential(key: key, facts: secretFacts)
        credentialKeys.remove(at: index)
        if index < credentialValues.count {
            credentialValues.remove(at: index)
        }
        updatedAt = Date()
    }

    /// Migrate any legacy plaintext credentials to Keychain.
    public func migrateToKeychain() {
        let facts = secretFacts
        for (index, key) in credentialKeys.enumerated() {
            guard index < credentialValues.count else { continue }
            let value = credentialValues[index]
            guard !value.isEmpty else { continue }

            if !ConnectorSecretSeam.required.credentialExists(key: key, facts: facts) {
                ConnectorSecretSeam.required.saveCredential(value, key: key, facts: facts)
            }
            credentialValues[index] = ""
        }
        ConnectorSecretSeam.required.synchronizeCredentialNamespaces(keys: credentialKeys, facts: facts)
    }

    /// Delete all Keychain entries when connector is deleted.
    public func cleanupKeychain() {
        if isStanfordOutlookMail {
            OutlookMailConnectionSeam.required.removeFromRegistry(connectorID: id)
        }
        ConnectorSecretSeam.required.deleteAllCredentials(facts: secretFacts)
        AuditLoggingSeam.required.audit(.connectorDeleted, category: "Keychain", fields: [
            "connector_id": id.uuidString,
            "service_type": serviceType
        ])
    }

    // MARK: - Stanford Outlook Mail (pure members)
    //
    // Moved from `Astra/Services/Capabilities/StanfordOutlookMail.swift` as
    // part of Track A2.5 — `testConnection()` below needs `isStanfordOutlookMail`
    // and `outlookEmail`, and both only touch this class's own stored
    // properties, so they belong here rather than behind a seam. The
    // "stanford_outlook_mail" service-type ID and "ASTRA_MAIL_EMAIL" config
    // key are duplicated (not imported) from `StanfordOutlookMail.serviceType`/
    // `.emailKey` in the app-target file, which remains the source of truth
    // for the rest of the Outlook OAuth/Graph flow — these are fixed
    // connector-type identifiers, not values expected to change independently
    // on either side.
    public var isStanfordOutlookMail: Bool {
        serviceType == "stanford_outlook_mail"
    }

    public func configValue(_ key: String) -> String {
        guard let index = configKeys.firstIndex(of: key), index < configValues.count else {
            return ""
        }
        return configValues[index]
    }

    public func setConfigValue(_ key: String, value: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedKey.isEmpty else { return }
        if let index = configKeys.firstIndex(of: normalizedKey) {
            if index < configValues.count {
                configValues[index] = value
            }
        } else {
            configKeys.append(normalizedKey)
            configValues.append(value)
        }
        updatedAt = Date()
    }

    public var outlookEmail: String {
        configValue("ASTRA_MAIL_EMAIL")
    }

    // MARK: - Connectivity Test

    /// Test the connection by hitting a known health endpoint.
    /// Returns (success, message) tuple.
    public func testConnection(
        store: SecretStore = SecretStoreSeam.required,
        transport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport(),
        source: String = "manual",
        workspaceID: UUID? = nil,
        packageID: String? = nil,
        traceID: String? = nil
    ) async -> (Bool, String) {
        let auditContext = connectorTestAuditFields(
            source: source,
            workspaceID: workspaceID,
            packageID: packageID,
            traceID: traceID
        )
        AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
            "result": "started"
        ], uniquingKeysWith: { _, new in new }))

        if isStanfordOutlookMail {
            do {
                let facts = ConnectorOutlookFacts(id: id, name: name, serviceType: serviceType, configKeys: configKeys, configValues: configValues)
                let result = try await OutlookMailConnectionSeam.required.testConnection(facts: facts)
                // Applied per changed key (not a wholesale configKeys/
                // configValues replacement) so a live config edit made to
                // self while the network call above was in flight isn't
                // silently rolled back to the pre-await snapshot.
                for (key, value) in result.changedConfigEntries {
                    setConfigValue(key, value: value)
                }
                updatedAt = Date()
                AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "microsoft_graph_oauth",
                    "credential_state": "authenticated",
                    "auth_verified": "true",
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "success"
                ], uniquingKeysWith: { _, new in new }))
                let identity = result.mail ?? result.userPrincipalName ?? outlookEmail
                return (true, identity.isEmpty ? "Connected to Microsoft Graph" : "Connected as \(identity)")
            } catch {
                AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "microsoft_graph_oauth",
                    "credential_state": "failed",
                    "auth_verified": "false",
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "oauth_failed",
                    "error_type": String(describing: type(of: error))
                ], uniquingKeysWith: { _, new in new }), level: .warning)
                return (false, error.localizedDescription)
            }
        }

        guard !baseURL.isEmpty, let base = URL(string: baseURL) else {
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "missing_base_url"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "No base URL configured")
        }

        if let violation = ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: baseURL,
            authMethod: authMethod,
            credentialKeys: credentialKeys
        ) {
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "unsafe_base_url"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, violation)
        }

        let creds = credentials(store: store)
        let missingKeys = missingCredentialKeys(store: store)
        if authMethod != "none", !credentialKeys.isEmpty, !missingKeys.isEmpty {
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "missing",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "missing_credentials",
                "missing_count": String(missingKeys.count)
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "Missing Keychain value: \(missingKeys.joined(separator: ", "))")
        }

        let normalizedServiceType = serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let method: String
        if normalizedServiceType == "redcap", testHTTPMethod.isEmpty || testHTTPMethod.uppercased() == "GET" {
            method = "POST"
        } else {
            method = testHTTPMethod.isEmpty ? "GET" : testHTTPMethod.uppercased()
        }

        if normalizedServiceType == "jira" {
            let outcome = await JiraConnectorAuthTester(
                connectorID: id,
                baseURL: base,
                authMethod: authMethod,
                credentials: creds,
                config: config,
                transport: transport
            ).test()
            AuditLoggingSeam.required.audit(
                .connectorTested,
                category: "Keychain",
                fields: outcome.auditFields(adding: auditContext.merging([
                    "credential_key_count": String(credentialKeys.count),
                    "connector_updated_at": Self.auditTimestamp(updatedAt)
                ], uniquingKeysWith: { _, new in new })),
                level: outcome.level
            )
            return (outcome.success, outcome.message)
        }

        let testPath: String
        switch normalizedServiceType {
        case "github": testPath = "/user"
        case "slack": testPath = "/auth.test"
        case "confluence": testPath = "/rest/api/content?limit=1"
        default: testPath = ""
        }

        let testURL = testPath.isEmpty ? base : ConnectorRequestBuilder.url(base: base, path: testPath)
        var request = URLRequest(url: testURL)
        request.httpMethod = method
        request.timeoutInterval = 10

        // For POST with api_key auth, send token as form body (e.g. REDCap).
        // REDCap uses the version endpoint for setup validation because it
        // exercises token auth without reading project metadata or records.
        if method == "POST" && authMethod == "api_key" {
            let token = creds.first { $0.key.contains("TOKEN") || $0.key.contains("KEY") }?.value
                ?? creds.first?.value ?? ""
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(encodedToken)&content=version&format=json&returnFormat=json".data(using: .utf8)
        } else {
            ConnectorRequestBuilder.applyAuthentication(authMethod: authMethod, credentials: creds, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        if normalizedServiceType == "redcap" {
            return await executeREDCapTestRequest(request, transport: transport, auditContext: auditContext)
        }
        return await executeTestRequest(request, transport: transport, auditContext: auditContext)
    }

    private func executeREDCapTestRequest(
        _ request: URLRequest,
        transport: any ConnectorHTTPTransport,
        auditContext: [String: String]
    ) async -> (Bool, String) {
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "connector_auth_v1",
                    "credential_state": "unknown",
                    "auth_verified": "false",
                    "credential_key_count": String(credentialKeys.count),
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "unknown_response"
                ], uniquingKeysWith: { _, new in new }), level: .warning)
                return (false, "Unknown response from REDCap")
            }

            if (200...299).contains(http.statusCode) {
                if let apiError = redcapAPIError(in: data) {
                    AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                        "credential_evidence": "connector_auth_v1",
                        "credential_state": "rejected",
                        "auth_verified": "false",
                        "credential_key_count": String(credentialKeys.count),
                        "connector_updated_at": Self.auditTimestamp(updatedAt),
                        "result": "api_error",
                        "http_status": String(http.statusCode)
                    ], uniquingKeysWith: { _, new in new }), level: .warning)
                    return (false, apiError)
                }

                AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "connector_auth_v1",
                    "credential_state": "authenticated",
                    "auth_verified": "true",
                    "credential_key_count": String(credentialKeys.count),
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "success",
                    "http_status": String(http.statusCode),
                    "endpoint_kind": "redcap.version"
                ], uniquingKeysWith: { _, new in new }))
                return (true, "REDCap version endpoint responded successfully")
            }

            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": http.statusCode == 401 || http.statusCode == 403 ? "rejected" : "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": http.statusCode == 401 || http.statusCode == 403 ? "auth_failed" : "http_error",
                "http_status": String(http.statusCode),
                "endpoint_kind": "redcap.version"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "REDCap returned HTTP \(http.statusCode)")
        } catch {
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "request_failed",
                "endpoint_kind": "redcap.version",
                "error_type": String(describing: type(of: error))
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, error.localizedDescription)
        }
    }

    private func redcapAPIError(in data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let string = String(data: data, encoding: .utf8) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.localizedCaseInsensitiveContains("error") {
                let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
                return oneLine.count > 180 ? String(oneLine.prefix(180)) : oneLine
            }
        }
        return nil
    }

    private func executeTestRequest(
        _ request: URLRequest,
        transport: any ConnectorHTTPTransport,
        auditContext: [String: String]
    ) async -> (Bool, String) {
        do {
            let (_, response) = try await transport.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                        "credential_evidence": "connector_auth_v1",
                        "credential_state": "authenticated",
                        "auth_verified": "true",
                        "credential_key_count": String(credentialKeys.count),
                        "connector_updated_at": Self.auditTimestamp(updatedAt),
                        "result": "success",
                        "http_status": String(http.statusCode)
                    ], uniquingKeysWith: { _, new in new }))
                    return (true, "HTTP \(http.statusCode) — connected successfully")
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                        "credential_evidence": "connector_auth_v1",
                        "credential_state": "rejected",
                        "auth_verified": "false",
                        "credential_key_count": String(credentialKeys.count),
                        "connector_updated_at": Self.auditTimestamp(updatedAt),
                        "result": "auth_failed",
                        "http_status": String(http.statusCode)
                    ], uniquingKeysWith: { _, new in new }), level: .warning)
                    return (false, "HTTP \(http.statusCode) — authentication failed")
                } else {
                    AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                        "credential_evidence": "connector_auth_v1",
                        "credential_state": "unknown",
                        "auth_verified": "false",
                        "credential_key_count": String(credentialKeys.count),
                        "connector_updated_at": Self.auditTimestamp(updatedAt),
                        "result": "http_error",
                        "http_status": String(http.statusCode)
                    ], uniquingKeysWith: { _, new in new }), level: .warning)
                    return (false, "HTTP \(http.statusCode)")
                }
            }
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "unknown_response"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "Unknown response")
        } catch {
            AuditLoggingSeam.required.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "request_failed",
                "error_type": String(describing: type(of: error))
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, error.localizedDescription)
        }
    }

    private func connectorTestAuditFields(
        source: String,
        workspaceID: UUID?,
        packageID: String?,
        traceID: String?
    ) -> [String: String] {
        var fields = [
            "source": source,
            "connector_id": id.uuidString,
            "connector_name": name,
            "service_type": serviceType,
            "is_global": String(isGlobal),
            "auth_method": authMethod,
            "credential_key_count": String(credentialKeys.count),
            "config_key_count": String(configKeys.count)
        ]
        if let workspaceID = workspaceID ?? workspace?.id {
            fields["workspace_id"] = workspaceID.uuidString
        }
        if let packageID, !packageID.isEmpty {
            fields["package_id"] = packageID
        }
        if let traceID, !traceID.isEmpty {
            fields["trace_id"] = traceID
        }
        return fields
    }

    private static func auditTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Summary line for display
    public var displaySummary: String {
        var parts: [String] = []
        if !baseURL.isEmpty {
            if let host = URL(string: baseURL)?.host {
                parts.append(host)
            } else {
                parts.append(baseURL)
            }
        }
        if !configKeys.isEmpty {
            let configSummary = configKeys.prefix(2).joined(separator: ", ")
            parts.append(configSummary)
        }
        return parts.isEmpty ? serviceType : parts.joined(separator: " · ")
    }
}

extension CharacterSet {
    /// Characters safe for a URL-encoded form *value* (excludes &, =, +).
    public static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=+")
        return cs
    }()
}
