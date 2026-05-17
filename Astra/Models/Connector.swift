import Foundation
import SwiftData
import ASTRACore

@Model
final class Connector {
    var id: UUID
    var name: String
    var serviceType: String  // "jira", "slack", "github", "database", "rest_api", "custom"
    var icon: String
    var connectorDescription: String

    // Connection
    var baseURL: String
    var authMethod: String  // "basic", "bearer", "api_key", "none"

    // Credentials (keys stored here, values in Keychain)
    var credentialKeys: [String]
    // Legacy: kept for migration. New credentials go to Keychain only.
    var credentialValues: [String]

    // Configuration (non-secret — visible in UI, e.g. projects, repos)
    var configKeys: [String]
    var configValues: [String]

    var isGlobal: Bool = false
    var testHTTPMethod: String = "GET"
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var skill: Skill?
    var workspace: Workspace?

    init(
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
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Computed

    /// Load credentials from Keychain. Legacy plaintext values are migrated at app launch.
    var credentials: [String: String] {
        credentials(store: KeychainSecretStore())
    }

    func credentials(store: SecretStore) -> [String: String] {
        let entityID = KeychainSecretStore.connectorEntityID(for: id)
        var result: [String: String] = [:]
        for key in credentialKeys {
            if let value = store.load(key: key, entityID: entityID) {
                result[key] = value
            }
        }
        return result
    }

    func missingCredentialKeys(store: SecretStore = KeychainSecretStore()) -> [String] {
        let resolved = credentials(store: store)
        return credentialKeys.filter { key in
            let value = resolved[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
        }
    }

    var config: [String: String] {
        Dictionary(zip(configKeys, configValues), uniquingKeysWith: { _, last in last })
    }

    /// All key-value pairs merged (for passing as env vars to the process)
    var allEnvironmentVariables: [String: String] {
        var merged = credentials
        for (k, v) in config { merged[k] = v }
        return merged
    }

    /// Save a credential value to Keychain and keep the key in SwiftData.
    func saveCredential(key: String, value: String) {
        let upperKey = key.uppercased()
        let saved = KeychainService.save(key: upperKey, value: value, connectorID: id, label: "Astra: \(name)")

        // Find existing entry case-insensitively to avoid duplicates
        if let idx = credentialKeys.firstIndex(where: { $0.caseInsensitiveCompare(upperKey) == .orderedSame }) {
            // Normalize key to uppercase and clear legacy value
            credentialKeys[idx] = upperKey
            if idx < credentialValues.count {
                credentialValues[idx] = ""
            }
        } else {
            credentialKeys.append(upperKey)
            credentialValues.append("")
        }
        updatedAt = Date()
        AppLogger.audit(.connectorSecretAdded, category: "Keychain", fields: [
            "connector_id": id.uuidString,
            "service_type": serviceType,
            "result": saved ? "stored" : "failed"
        ], level: saved ? .info : .warning)
    }

    /// Remove a credential from both Keychain and SwiftData.
    func removeCredential(at index: Int) {
        guard index < credentialKeys.count else { return }
        let key = credentialKeys[index]
        let deleted = KeychainService.delete(key: key, connectorID: id)
        credentialKeys.remove(at: index)
        if index < credentialValues.count {
            credentialValues.remove(at: index)
        }
        updatedAt = Date()
        AppLogger.audit(.connectorSecretRemoved, category: "Keychain", fields: [
            "connector_id": id.uuidString,
            "service_type": serviceType,
            "result": deleted ? "removed" : "failed"
        ], level: deleted ? .info : .warning)
    }

    /// Migrate any legacy plaintext credentials to Keychain.
    func migrateToKeychain() {
        for (idx, key) in credentialKeys.enumerated() {
            guard idx < credentialValues.count else { continue }
            let value = credentialValues[idx]
            guard !value.isEmpty else { continue }
            // Only migrate if not already in Keychain
            if !KeychainService.exists(key: key, connectorID: id) {
                KeychainService.save(key: key, value: value, connectorID: id, label: "Astra: \(name)")
            }
            credentialValues[idx] = "" // Clear plaintext
        }
    }

    /// Delete all Keychain entries when connector is deleted.
    func cleanupKeychain() {
        if isStanfordOutlookMail {
            StanfordOutlookMailRegistry.remove(connectorID: id)
        }
        KeychainService.deleteAll(connectorID: id)
        AppLogger.audit(.connectorDeleted, category: "Keychain", fields: [
            "connector_id": id.uuidString,
            "service_type": serviceType
        ])
    }

    // MARK: - Connectivity Test

    /// Test the connection by hitting a known health endpoint.
    /// Returns (success, message) tuple.
    func testConnection(
        store: SecretStore = KeychainSecretStore(),
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
        AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
            "result": "started"
        ], uniquingKeysWith: { _, new in new }))

        if isStanfordOutlookMail {
            do {
                let me = try await StanfordOutlookMailGraphService().testConnection(connector: self)
                AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "microsoft_graph_oauth",
                    "credential_state": "authenticated",
                    "auth_verified": "true",
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "success"
                ], uniquingKeysWith: { _, new in new }))
                let identity = me.mail ?? me.userPrincipalName ?? outlookEmail
                return (true, identity.isEmpty ? "Connected to Microsoft Graph" : "Connected as \(identity)")
            } catch {
                AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
            AppLogger.audit(
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
        // REDCap uses project info because it validates the token without
        // exporting records or metadata that may contain PHI.
        if method == "POST" && authMethod == "api_key" {
            let token = creds.first { $0.key.contains("TOKEN") || $0.key.contains("KEY") }?.value
                ?? creds.first?.value ?? ""
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(encodedToken)&content=project&format=json&returnFormat=json".data(using: .utf8)
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
                AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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

                AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                    "credential_evidence": "connector_auth_v1",
                    "credential_state": "authenticated",
                    "auth_verified": "true",
                    "credential_key_count": String(credentialKeys.count),
                    "connector_updated_at": Self.auditTimestamp(updatedAt),
                    "result": "success",
                    "http_status": String(http.statusCode),
                    "endpoint_kind": "redcap.project"
                ], uniquingKeysWith: { _, new in new }))
                return (true, "REDCap project endpoint responded successfully")
            }

            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": http.statusCode == 401 || http.statusCode == 403 ? "rejected" : "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": http.statusCode == 401 || http.statusCode == 403 ? "auth_failed" : "http_error",
                "http_status": String(http.statusCode),
                "endpoint_kind": "redcap.project"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "REDCap returned HTTP \(http.statusCode)")
        } catch {
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "request_failed",
                "endpoint_kind": "redcap.project",
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
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
                "credential_evidence": "connector_auth_v1",
                "credential_state": "unknown",
                "auth_verified": "false",
                "credential_key_count": String(credentialKeys.count),
                "connector_updated_at": Self.auditTimestamp(updatedAt),
                "result": "unknown_response"
            ], uniquingKeysWith: { _, new in new }), level: .warning)
            return (false, "Unknown response")
        } catch {
            AppLogger.audit(.connectorTested, category: "Keychain", fields: auditContext.merging([
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
    var displaySummary: String {
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
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=+")
        return cs
    }()
}
