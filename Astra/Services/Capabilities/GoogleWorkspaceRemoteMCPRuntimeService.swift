import Foundation
import ASTRACore
import ASTRAModels

protocol GoogleWorkspaceRemoteMCPTokenResolving: AnyObject {
    func accessToken(for profile: GoogleOAuthAccountProfile, requiredScopes: [String]) async -> GoogleWorkspaceRemoteMCPTokenResult
}

final class GoogleWorkspaceRemoteMCPVaultTokenResolver: GoogleWorkspaceRemoteMCPTokenResolving {
    private let vault: GoogleOAuthCredentialVault
    private let tokenService: GoogleOAuthTokenService

    init(vault: GoogleOAuthCredentialVault = GoogleOAuthCredentialVault(), tokenService: GoogleOAuthTokenService) {
        self.vault = vault
        self.tokenService = tokenService
    }

    func accessToken(for profile: GoogleOAuthAccountProfile, requiredScopes: [String]) async -> GoogleWorkspaceRemoteMCPTokenResult {
        let missingScopes = GoogleOAuthScopeNormalizer.missing(required: requiredScopes, granted: profile.grantedScopes)
        guard missingScopes.isEmpty else { return .missingScopes(missingScopes) }
        do {
            return .success(try vault.accessToken(for: profile))
        } catch GoogleOAuthCredentialFailure.expiredToken {
            do {
                try await tokenService.refreshAccessToken(for: profile)
                return .success(try vault.accessToken(for: profile))
            } catch {
                return .refreshFailed(error.localizedDescription)
            }
        } catch GoogleOAuthCredentialFailure.missingAccount {
            return .missingAccount
        } catch GoogleOAuthCredentialFailure.missingScope(let scopes) {
            return .missingScopes(scopes)
        } catch {
            return .refreshFailed(error.localizedDescription)
        }
    }
}

protocol GoogleWorkspaceMCPPolicyEnforcing {
    func decision(product: GoogleWorkspaceRemoteMCPProduct, toolName: String, family: GoogleWorkspaceRemoteMCPToolFamily) -> GoogleWorkspaceRemoteMCPPolicyDecision
}

struct AllowingGoogleWorkspaceMCPPolicyEnforcer: GoogleWorkspaceMCPPolicyEnforcing {
    func decision(product: GoogleWorkspaceRemoteMCPProduct, toolName: String, family: GoogleWorkspaceRemoteMCPToolFamily) -> GoogleWorkspaceRemoteMCPPolicyDecision {
        .allowed
    }
}

struct DenyingGoogleWorkspaceMCPPolicyEnforcer: GoogleWorkspaceMCPPolicyEnforcing {
    var reason: String

    func decision(product: GoogleWorkspaceRemoteMCPProduct, toolName: String, family: GoogleWorkspaceRemoteMCPToolFamily) -> GoogleWorkspaceRemoteMCPPolicyDecision {
        .denied(reason)
    }
}

final class GoogleWorkspaceRemoteMCPRuntimeService {
    private let tokenResolver: any GoogleWorkspaceRemoteMCPTokenResolving
    private let policyEnforcer: any GoogleWorkspaceMCPPolicyEnforcing
    private let gatewayBaseURL: URL

    init(
        tokenResolver: any GoogleWorkspaceRemoteMCPTokenResolving,
        policyEnforcer: any GoogleWorkspaceMCPPolicyEnforcing = AllowingGoogleWorkspaceMCPPolicyEnforcer(),
        gatewayBaseURL: URL
    ) {
        self.tokenResolver = tokenResolver
        self.policyEnforcer = policyEnforcer
        self.gatewayBaseURL = gatewayBaseURL
    }

    func routePlan(
        product id: GoogleWorkspaceRemoteMCPProductID,
        toolName: String,
        account: GoogleOAuthAccountProfile?
    ) async throws -> GoogleWorkspaceRemoteMCPRoutePlan {
        guard let account else { throw GoogleWorkspaceRemoteMCPBackendFailure.missingAccount }
        guard let product = GoogleWorkspaceRemoteMCPRegistry.product(id) else {
            throw GoogleWorkspaceRemoteMCPBackendFailure.unsupportedProduct(id)
        }
        guard let family = product.toolFamilies[toolName] else {
            throw GoogleWorkspaceRemoteMCPBackendFailure.unsupportedTool(toolName)
        }
        switch policyEnforcer.decision(product: product, toolName: toolName, family: family) {
        case .allowed:
            break
        case .denied(let reason):
            throw GoogleWorkspaceRemoteMCPBackendFailure.policyDenied(reason)
        }
        let tokenResult = await tokenResolver.accessToken(for: account, requiredScopes: product.requiredScopes)
        let result = GoogleWorkspaceRemoteMCPBackendPlanner.plan(
            product: id,
            toolName: toolName,
            dependencies: .init(
                oauthVaultAvailable: true,
                localGatewayAvailable: true,
                policyEnforcerAvailable: true,
                googleMCPAvailable: true,
                accountID: account.id.uuidString,
                grantedScopes: Set(account.grantedScopes),
                tokenResult: tokenResult,
                policyDecision: .allowed,
                gatewayBaseURL: gatewayBaseURL
            )
        )
        switch result {
        case .success(let plan):
            return plan
        case .failure(let failure):
            throw failure
        }
    }
}
