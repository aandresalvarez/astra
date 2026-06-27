import Foundation

enum GoogleWorkspaceRemoteMCPTokenResult: Equatable, Sendable {
    case success(String)
    case missingAccount
    case missingScopes([String])
    case refreshFailed(String)
}

enum GoogleWorkspaceRemoteMCPPolicyDecision: Equatable, Sendable {
    case allowed
    case denied(String)
}

struct GoogleWorkspaceRemoteMCPBackendDependencies: Equatable, Sendable {
    var oauthVaultAvailable: Bool
    var localGatewayAvailable: Bool
    var policyEnforcerAvailable: Bool
    var googleMCPAvailable: Bool
    var accountID: String?
    var grantedScopes: Set<String>
    var tokenResult: GoogleWorkspaceRemoteMCPTokenResult
    var policyDecision: GoogleWorkspaceRemoteMCPPolicyDecision
    var gatewayBaseURL: URL

    init(
        oauthVaultAvailable: Bool,
        localGatewayAvailable: Bool,
        policyEnforcerAvailable: Bool,
        googleMCPAvailable: Bool,
        accountID: String?,
        grantedScopes: Set<String>,
        tokenResult: GoogleWorkspaceRemoteMCPTokenResult,
        policyDecision: GoogleWorkspaceRemoteMCPPolicyDecision,
        gatewayBaseURL: URL
    ) {
        self.oauthVaultAvailable = oauthVaultAvailable
        self.localGatewayAvailable = localGatewayAvailable
        self.policyEnforcerAvailable = policyEnforcerAvailable
        self.googleMCPAvailable = googleMCPAvailable
        self.accountID = accountID
        self.grantedScopes = grantedScopes
        self.tokenResult = tokenResult
        self.policyDecision = policyDecision
        self.gatewayBaseURL = gatewayBaseURL
    }
}

enum GoogleWorkspaceRemoteMCPBackendFailure: Equatable, Sendable {
    case missingOAuthVault
    case missingLocalGateway
    case missingPolicyEnforcer
    case googleMCPUnavailable
    case missingAccount
    case missingScopes([String])
    case tokenRefreshFailed(String)
    case policyDenied(String)
    case unsupportedProduct(GoogleWorkspaceRemoteMCPProductID)
    case unsupportedTool(String)
}

struct GoogleWorkspaceRemoteMCPRoutePlan: Equatable, Sendable {
    var product: GoogleWorkspaceRemoteMCPProduct
    var toolName: String
    var gatewayURL: URL
    var upstreamURL: URL
    var authorizationHeader: String
    var accountID: String
    var requiredScopes: [String]
    var toolFamily: GoogleWorkspaceRemoteMCPToolFamily
}

enum GoogleWorkspaceRemoteMCPBackendPlanResult: Equatable, Sendable {
    case success(GoogleWorkspaceRemoteMCPRoutePlan)
    case failure(GoogleWorkspaceRemoteMCPBackendFailure)

    var success: GoogleWorkspaceRemoteMCPRoutePlan? {
        guard case let .success(plan) = self else { return nil }
        return plan
    }

    var failure: GoogleWorkspaceRemoteMCPBackendFailure? {
        guard case let .failure(reason) = self else { return nil }
        return reason
    }
}

enum GoogleWorkspaceRemoteMCPBackendPlanner {
    static func plan(
        product id: GoogleWorkspaceRemoteMCPProductID,
        toolName: String,
        dependencies: GoogleWorkspaceRemoteMCPBackendDependencies
    ) -> GoogleWorkspaceRemoteMCPBackendPlanResult {
        guard dependencies.oauthVaultAvailable else { return .failure(.missingOAuthVault) }
        guard dependencies.localGatewayAvailable else { return .failure(.missingLocalGateway) }
        guard dependencies.policyEnforcerAvailable else { return .failure(.missingPolicyEnforcer) }
        guard dependencies.googleMCPAvailable else { return .failure(.googleMCPUnavailable) }
        guard let accountID = dependencies.accountID, !accountID.isEmpty else { return .failure(.missingAccount) }
        guard let product = GoogleWorkspaceRemoteMCPRegistry.product(id) else { return .failure(.unsupportedProduct(id)) }
        guard let toolFamily = product.toolFamilies[toolName] else { return .failure(.unsupportedTool(toolName)) }

        let missingScopes = product.requiredScopes.filter { !dependencies.grantedScopes.contains($0) }
        guard missingScopes.isEmpty else { return .failure(.missingScopes(missingScopes)) }

        let token: String
        switch dependencies.tokenResult {
        case let .success(accessToken):
            token = accessToken
        case .missingAccount:
            return .failure(.missingAccount)
        case let .missingScopes(scopes):
            return .failure(.missingScopes(scopes))
        case let .refreshFailed(reason):
            return .failure(.tokenRefreshFailed(reason))
        }

        switch dependencies.policyDecision {
        case .allowed:
            break
        case let .denied(reason):
            return .failure(.policyDenied(reason))
        }

        return .success(GoogleWorkspaceRemoteMCPRoutePlan(
            product: product,
            toolName: toolName,
            gatewayURL: gatewayURL(for: id, baseURL: dependencies.gatewayBaseURL),
            upstreamURL: product.endpoint,
            authorizationHeader: "Bearer \(token)",
            accountID: accountID,
            requiredScopes: product.requiredScopes,
            toolFamily: toolFamily
        ))
    }

    private static func gatewayURL(
        for id: GoogleWorkspaceRemoteMCPProductID,
        baseURL: URL
    ) -> URL {
        baseURL
            .appendingPathComponent("mcp")
            .appendingPathComponent("google-workspace")
            .appendingPathComponent(id.rawValue)
    }
}
