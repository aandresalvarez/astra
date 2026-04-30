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
        KeychainService.deleteAll(connectorID: id)
        AppLogger.audit(.connectorDeleted, category: "Keychain", fields: [
            "connector_id": id.uuidString,
            "service_type": serviceType
        ])
    }

    // MARK: - Connectivity Test

    /// Test the connection by hitting a known health endpoint.
    /// Returns (success, message) tuple.
    func testConnection() async -> (Bool, String) {
        guard !baseURL.isEmpty, let base = URL(string: baseURL) else {
            AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                "connector_id": id.uuidString,
                "service_type": serviceType,
                "result": "missing_base_url"
            ], level: .warning)
            return (false, "No base URL configured")
        }

        let creds = credentials
        let missingKeys = missingCredentialKeys()
        if authMethod != "none", !credentialKeys.isEmpty, !missingKeys.isEmpty {
            AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                "connector_id": id.uuidString,
                "service_type": serviceType,
                "result": "missing_credentials",
                "missing_count": String(missingKeys.count)
            ], level: .warning)
            return (false, "Missing Keychain value: \(missingKeys.joined(separator: ", "))")
        }

        let method = testHTTPMethod.isEmpty ? "GET" : testHTTPMethod.uppercased()

        let testPath: String
        switch serviceType {
        case "jira": testPath = "/rest/api/3/myself"
        case "github": testPath = "/user"
        case "slack": testPath = "/auth.test"
        case "confluence": testPath = "/rest/api/content?limit=1"
        default: testPath = ""
        }

        let testURL = testPath.isEmpty ? base : base.appendingPathComponent(testPath)
        var request = URLRequest(url: testURL)
        request.httpMethod = method
        request.timeoutInterval = 10

        // For POST with api_key auth, send token as form body (e.g. REDCap)
        if method == "POST" && authMethod == "api_key" {
            let token = creds.first { $0.key.contains("TOKEN") || $0.key.contains("KEY") }?.value
                ?? creds.first?.value ?? ""
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(encodedToken)&content=version".data(using: .utf8)
        } else {
            switch authMethod {
            case "basic":
                let email = creds.first { $0.key.contains("EMAIL") || $0.key.contains("USER") }?.value ?? ""
                let token = creds.first { $0.key.contains("TOKEN") || $0.key.contains("PASSWORD") || $0.key.contains("KEY") }?.value ?? ""
                if !email.isEmpty || !token.isEmpty {
                    let combined = "\(email):\(token)"
                    if let data = combined.data(using: .utf8) {
                        request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                    }
                }
            case "bearer":
                let token = creds.first { $0.key.contains("TOKEN") || $0.key.contains("KEY") }?.value ?? ""
                if !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            case "api_key":
                let token = creds.first?.value ?? ""
                if !token.isEmpty {
                    request.setValue(token, forHTTPHeaderField: "Authorization")
                }
            default:
                break
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        return await executeTestRequest(request)
    }

    private func executeTestRequest(_ request: URLRequest) async -> (Bool, String) {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                        "connector_id": id.uuidString,
                        "service_type": serviceType,
                        "result": "success",
                        "http_status": String(http.statusCode)
                    ])
                    return (true, "HTTP \(http.statusCode) — connected successfully")
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                        "connector_id": id.uuidString,
                        "service_type": serviceType,
                        "result": "auth_failed",
                        "http_status": String(http.statusCode)
                    ], level: .warning)
                    return (false, "HTTP \(http.statusCode) — authentication failed")
                } else {
                    AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                        "connector_id": id.uuidString,
                        "service_type": serviceType,
                        "result": "http_error",
                        "http_status": String(http.statusCode)
                    ], level: .warning)
                    return (false, "HTTP \(http.statusCode)")
                }
            }
            AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                "connector_id": id.uuidString,
                "service_type": serviceType,
                "result": "unknown_response"
            ], level: .warning)
            return (false, "Unknown response")
        } catch {
            AppLogger.audit(.connectorTested, category: "Keychain", fields: [
                "connector_id": id.uuidString,
                "service_type": serviceType,
                "result": "request_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            return (false, error.localizedDescription)
        }
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
