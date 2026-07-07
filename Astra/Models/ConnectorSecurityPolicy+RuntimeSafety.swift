import Foundation
import ASTRACore

/// `isRuntimeSafe(_:)` stays out of `ASTRACore/ConnectorSecurityPolicy.swift`
/// since it takes the `Connector` `@Model` type, which cannot appear in
/// `ASTRACore` (the pure, string-only `credentialTransportViolation` lives
/// there instead). Moved here from
/// `Astra/Services/Runtime/SecurityPolicies.swift` for Track A4
/// (`ASTRAPersistence`), which needs it from `WorkspaceConfigManager.swift`.
public extension ConnectorSecurityPolicy {
    static func isRuntimeSafe(_ connector: Connector) -> Bool {
        credentialTransportViolation(
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys
        ) == nil
    }
}
