import Foundation

protocol ConnectorHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, cancellationToken: LocalAgentCancellationToken?) async throws -> (Data, URLResponse)
}

extension ConnectorHTTPTransport {
    func data(for request: URLRequest, cancellationToken _: LocalAgentCancellationToken?) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

struct URLSessionConnectorHTTPTransport: ConnectorHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, cancellationToken: nil)
    }

    func data(for request: URLRequest, cancellationToken: LocalAgentCancellationToken?) async throws -> (Data, URLResponse) {
        try await LocalAgentCancellableDataLoader.data(for: request, cancellationToken: cancellationToken)
    }
}

enum ConnectorRequestBuilder {
    static func url(
        base: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        url(base: base, path: path, queryItems: queryItems, pathIsPercentEncoded: false)
    }

    static func urlWithPercentEncodedPath(
        base: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        url(base: base, path: path, queryItems: queryItems, pathIsPercentEncoded: true)
    }

    private static func url(
        base: URL,
        path: String,
        queryItems: [URLQueryItem],
        pathIsPercentEncoded: Bool
    ) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }

        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathWithoutQuery = parts.first.map(String.init) ?? ""
        let embeddedQueryItems: [URLQueryItem]
        if parts.count > 1 {
            var queryComponents = URLComponents()
            queryComponents.percentEncodedQuery = String(parts[1])
            embeddedQueryItems = queryComponents.queryItems ?? []
        } else {
            embeddedQueryItems = []
        }

        let basePath = (pathIsPercentEncoded ? components.percentEncodedPath : components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = pathWithoutQuery.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedPath = "/" + [basePath, childPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        if pathIsPercentEncoded {
            components.percentEncodedPath = resolvedPath
        } else {
            components.path = resolvedPath
        }
        let combinedQueryItems = (components.queryItems ?? []) + embeddedQueryItems + queryItems
        components.queryItems = combinedQueryItems.isEmpty ? nil : combinedQueryItems
        return components.url ?? base
    }

    static func applyAuthentication(
        authMethod: String,
        credentials: [String: String],
        to request: inout URLRequest
    ) {
        switch authMethod {
        case "basic":
            let email = credentials.first { key, _ in
                key.localizedCaseInsensitiveContains("EMAIL")
                    || key.localizedCaseInsensitiveContains("USER")
            }?.value ?? ""
            let token = credentials.first { key, _ in
                key.localizedCaseInsensitiveContains("TOKEN")
                    || key.localizedCaseInsensitiveContains("PASSWORD")
                    || key.localizedCaseInsensitiveContains("KEY")
            }?.value ?? ""
            if !email.isEmpty || !token.isEmpty {
                let combined = "\(email):\(token)"
                if let data = combined.data(using: .utf8) {
                    request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }
        case "bearer":
            let token = credentials.first { key, _ in
                key.localizedCaseInsensitiveContains("TOKEN")
                    || key.localizedCaseInsensitiveContains("KEY")
            }?.value ?? ""
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case "api_key":
            let token = credentials.first?.value ?? ""
            if !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
        default:
            break
        }
    }
}

struct ConnectorTestOutcome {
    let success: Bool
    let message: String
    let level: LogLevel
    let fields: [String: String]

    func auditFields(adding extra: [String: String]) -> [String: String] {
        fields.merging(extra) { current, _ in current }
    }
}

struct JiraConnectorAuthTester {
    let connectorID: UUID
    let baseURL: URL
    let authMethod: String
    let credentials: [String: String]
    let config: [String: String]
    let transport: any ConnectorHTTPTransport

    func test() async -> ConnectorTestOutcome {
        let global = await probe(
            endpointKind: "jira.mypermissions",
            path: "/rest/api/3/mypermissions",
            queryItems: [
                URLQueryItem(name: "permissions", value: "BROWSE_PROJECTS")
            ]
        )

        switch global.statusCode {
        case 200:
            return await classifyGlobalPermissions(global)
        case 401, 403:
            let myself = await probeMyself()
            return classifyRejectedPermissionProbe(global, fallback: myself)
        case 404:
            return outcome(
                result: "endpoint_unavailable",
                endpointKind: "jira.mypermissions",
                statusCode: global.statusCode,
                message: "Jira permission endpoint was not found. Verify the Jira Cloud base URL or Data Center support.",
                level: .warning
            )
        case nil:
            return outcome(
                result: "request_failed",
                endpointKind: "jira.mypermissions",
                message: global.errorMessage ?? "Jira permission probe failed",
                level: .warning
            )
        default:
            return outcome(
                result: "http_error",
                endpointKind: "jira.mypermissions",
                statusCode: global.statusCode,
                message: "Jira permission probe returned HTTP \(global.statusCode ?? 0)",
                level: .warning
            )
        }
    }

    private func probeMyself() async -> ProbeResult {
        await probe(
            endpointKind: "jira.myself",
            path: "/rest/api/3/myself",
            queryItems: []
        )
    }

    private func classifyRejectedPermissionProbe(
        _ global: ProbeResult,
        fallback myself: ProbeResult
    ) -> ConnectorTestOutcome {
        switch myself.statusCode {
        case let status? where (200..<300).contains(status):
            return outcome(
                result: "endpoint_scope_failure",
                endpointKind: "jira.mypermissions",
                statusCode: global.statusCode,
                message: "Jira authenticated through /myself, but the permission endpoint was rejected. Check token scopes, service-account auth mode, or Jira gateway URL.",
                level: .warning,
                fields: [
                    "fallback_endpoint_kind": "jira.myself",
                    "fallback_http_status": String(status)
                ]
            )
        case 401, 403:
            var fields: [String: String] = [
                "auth_endpoint_kind": "jira.myself",
                "auth_http_status": String(myself.statusCode ?? 0),
                "primary_endpoint_kind": "jira.mypermissions",
                "primary_http_status": String(global.statusCode ?? 0)
            ]
            if let reason = myself.seraphLoginReason {
                fields["seraph_loginreason"] = reason
            }
            return outcome(
                result: "auth_failed",
                endpointKind: "jira.myself",
                statusCode: myself.statusCode,
                message: "Jira rejected the credentials in both permission and account probes. Verify the Jira email and API token pair; Jira Cloud Basic auth requires the Atlassian account email, not a username.",
                level: .warning,
                fields: fields
            )
        case 404:
            return outcome(
                result: "endpoint_unavailable",
                endpointKind: "jira.myself",
                statusCode: myself.statusCode,
                message: "Jira account endpoint was not found after the permission endpoint was rejected. Verify the Jira Cloud base URL or Data Center support.",
                level: .warning,
                fields: [
                    "primary_endpoint_kind": "jira.mypermissions",
                    "primary_http_status": String(global.statusCode ?? 0)
                ]
            )
        case nil:
            return outcome(
                result: "request_failed",
                endpointKind: "jira.myself",
                message: myself.errorMessage ?? "Jira account fallback probe failed after the permission endpoint was rejected",
                level: .warning,
                fields: [
                    "primary_endpoint_kind": "jira.mypermissions",
                    "primary_http_status": String(global.statusCode ?? 0)
                ]
            )
        default:
            return outcome(
                result: "http_error",
                endpointKind: "jira.myself",
                statusCode: myself.statusCode,
                message: "Jira account fallback probe returned HTTP \(myself.statusCode ?? 0) after the permission endpoint was rejected",
                level: .warning,
                fields: [
                    "primary_endpoint_kind": "jira.mypermissions",
                    "primary_http_status": String(global.statusCode ?? 0)
                ]
            )
        }
    }

    private func classifyGlobalPermissions(_ global: ProbeResult) async -> ConnectorTestOutcome {
        guard permission("BROWSE_PROJECTS", in: global.data) == true else {
            return outcome(
                result: "missing_permission",
                endpointKind: "jira.mypermissions",
                statusCode: global.statusCode,
                message: "Jira authenticated, but this account lacks BROWSE_PROJECTS permission.",
                level: .warning,
                fields: ["permission": "BROWSE_PROJECTS"]
            )
        }

        let projects = configuredProjects
        guard !projects.isEmpty else {
            return outcome(
                result: "authenticated",
                endpointKind: "jira.mypermissions",
                statusCode: global.statusCode,
                message: "Jira authenticated; BROWSE_PROJECTS permission is available.",
                level: .info,
                fields: ["project_count": "0"]
            )
        }

        for (index, project) in projects.enumerated() {
            let scoped = await probe(
                endpointKind: "jira.project_permissions",
                path: "/rest/api/3/mypermissions",
                queryItems: [
                    URLQueryItem(name: "projectKey", value: project),
                    URLQueryItem(name: "permissions", value: "BROWSE_PROJECTS,CREATE_ISSUES")
                ]
            )

            switch scoped.statusCode {
            case 200:
                if permission("BROWSE_PROJECTS", in: scoped.data) != true {
                    return outcome(
                        result: "project_not_visible",
                        endpointKind: "jira.project_permissions",
                        statusCode: scoped.statusCode,
                        message: "Jira authenticated, but project \(project) is not visible to this account.",
                        level: .warning,
                        fields: [
                            "project_index": String(index),
                            "project_count": String(projects.count),
                            "permission": "BROWSE_PROJECTS"
                        ]
                    )
                }
                if permission("CREATE_ISSUES", in: scoped.data) != true {
                    return outcome(
                        result: "missing_permission",
                        endpointKind: "jira.project_permissions",
                        statusCode: scoped.statusCode,
                        message: "Jira authenticated, but this account lacks CREATE_ISSUES for project \(project).",
                        level: .warning,
                        fields: [
                            "project_index": String(index),
                            "project_count": String(projects.count),
                            "permission": "CREATE_ISSUES"
                        ]
                    )
                }
            case 404:
                return outcome(
                    result: "project_not_visible",
                    endpointKind: "jira.project_permissions",
                    statusCode: scoped.statusCode,
                    message: "Jira authenticated, but project \(project) is not visible or the project key is wrong.",
                    level: .warning,
                    fields: [
                        "project_index": String(index),
                        "project_count": String(projects.count)
                    ]
                )
            case 401, 403:
                return outcome(
                    result: "endpoint_scope_failure",
                    endpointKind: "jira.project_permissions",
                    statusCode: scoped.statusCode,
                    message: "Jira authenticated globally, but the project permission probe for \(project) was rejected. Check token scopes and project access.",
                    level: .warning,
                    fields: [
                        "project_index": String(index),
                        "project_count": String(projects.count)
                    ]
                )
            case nil:
                return outcome(
                    result: "request_failed",
                    endpointKind: "jira.project_permissions",
                    message: scoped.errorMessage ?? "Jira project permission probe failed",
                    level: .warning,
                    fields: [
                        "project_index": String(index),
                        "project_count": String(projects.count)
                    ]
                )
            default:
                return outcome(
                    result: "http_error",
                    endpointKind: "jira.project_permissions",
                    statusCode: scoped.statusCode,
                    message: "Jira project permission probe returned HTTP \(scoped.statusCode ?? 0)",
                    level: .warning,
                    fields: [
                        "project_index": String(index),
                        "project_count": String(projects.count)
                    ]
                )
            }
        }

        return outcome(
            result: "authenticated",
            endpointKind: "jira.project_permissions",
            statusCode: 200,
            message: "Jira authenticated; configured projects are visible and CREATE_ISSUES is available.",
            level: .info,
            fields: ["project_count": String(projects.count)]
        )
    }

    private var configuredProjects: [String] {
        (config["JIRA_PROJECTS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private func probe(
        endpointKind: String,
        path: String,
        queryItems: [URLQueryItem]
    ) async -> ProbeResult {
        let url = ConnectorRequestBuilder.url(base: baseURL, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ConnectorRequestBuilder.applyAuthentication(authMethod: authMethod, credentials: credentials, to: &request)

        do {
            let (data, response) = try await transport.data(for: request)
            let http = response as? HTTPURLResponse
            return ProbeResult(
                endpointKind: endpointKind,
                statusCode: http?.statusCode,
                data: data,
                headers: http?.allHeaderFields ?? [:],
                errorMessage: nil
            )
        } catch {
            return ProbeResult(
                endpointKind: endpointKind,
                statusCode: nil,
                data: Data(),
                headers: [:],
                errorMessage: error.localizedDescription
            )
        }
    }

    private func permission(_ key: String, in data: Data) -> Bool? {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(JiraPermissionsResponse.self, from: data) else {
            return nil
        }
        return decoded.permissions[key]?.havePermission
    }

    private func outcome(
        result: String,
        endpointKind: String,
        statusCode: Int? = nil,
        message: String,
        level: LogLevel,
        fields: [String: String] = [:]
    ) -> ConnectorTestOutcome {
        var auditFields = fields
        auditFields["endpoint_kind"] = endpointKind
        auditFields["result"] = result
        auditFields["credential_evidence"] = "connector_auth_v1"
        auditFields["credential_state"] = credentialState(for: result)
        auditFields["auth_verified"] = authVerified(for: result) ? "true" : "false"
        if let statusCode {
            auditFields["http_status"] = String(statusCode)
        }
        return ConnectorTestOutcome(
            success: level == .info,
            message: message,
            level: level,
            fields: auditFields
        )
    }

    private func credentialState(for result: String) -> String {
        switch result {
        case "authenticated", "missing_permission", "project_not_visible", "endpoint_scope_failure":
            "authenticated"
        case "auth_failed", "missing_credentials":
            "rejected"
        case "request_failed", "endpoint_unavailable", "http_error":
            "unknown"
        default:
            "unknown"
        }
    }

    private func authVerified(for result: String) -> Bool {
        switch result {
        case "authenticated", "missing_permission", "project_not_visible", "endpoint_scope_failure":
            true
        default:
            false
        }
    }
}

private struct ProbeResult {
    let endpointKind: String
    let statusCode: Int?
    let data: Data
    let headers: [AnyHashable: Any]
    let errorMessage: String?

    var seraphLoginReason: String? {
        headers.first { key, _ in
            String(describing: key).caseInsensitiveCompare("x-seraph-loginreason") == .orderedSame
        }.map { String(describing: $0.value) }
    }
}

private struct JiraPermissionsResponse: Decodable {
    let permissions: [String: JiraPermission]
}

private struct JiraPermission: Decodable {
    let havePermission: Bool
}
