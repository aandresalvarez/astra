import Foundation

// Moved (the pure, string-only half) from
// `Astra/Services/Runtime/SecurityPolicies.swift` as part of Track A2
// (breaking the Models↔Runtime cycle): `Astra/Models/Connector.swift` calls
// `credentialTransportViolation` directly. `isRuntimeSafe(_ connector:)` stays
// in the app target's `ConnectorSecurityPolicy` (an extension on this type)
// since it takes the `Connector` `@Model` type, which cannot appear in
// ASTRACore. No logic changed.
public enum ConnectorSecurityPolicy {
    public static func credentialTransportViolation(
        baseURL: String,
        authMethod: String,
        credentialKeys: [String]
    ) -> String? {
        guard requiresProtectedTransport(authMethod: authMethod, credentialKeys: credentialKeys) else {
            return nil
        }

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            return "Connector base URL must be HTTPS, or loopback HTTP, before credentials can be used."
        }

        if scheme == "https" {
            return nil
        }
        if scheme == "http", isLoopbackHost(url.host) {
            return nil
        }
        return "Connector base URL must be HTTPS, or loopback HTTP, before credentials can be used."
    }

    private static func requiresProtectedTransport(authMethod: String, credentialKeys: [String]) -> Bool {
        let normalizedAuth = authMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedAuth != "none" || !credentialKeys.isEmpty
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
    }
}
