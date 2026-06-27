import Foundation

struct MCPToolGatewayResponse: Sendable, Equatable {
    var summary: String
}

protocol MCPToolForwarding: Sendable {
    func forward(_ request: MCPToolPolicyRequest) async throws -> MCPToolGatewayResponse
}

enum MCPToolPolicyGatewayError: Error, Equatable {
    case denied(MCPToolPolicyDenialReason)
}

struct MCPToolPolicyGatewayAdapter<Forwarder: MCPToolForwarding>: Sendable {
    var policyEngine: MCPToolPolicyEngine
    var forwarder: Forwarder

    func call(_ request: MCPToolPolicyRequest) async throws -> MCPToolGatewayResponse {
        let decision = policyEngine.evaluate(request)
        guard decision.isAllowed else {
            throw MCPToolPolicyGatewayError.denied(decision.denialReason ?? .unclassifiedTool)
        }
        return try await forwarder.forward(request)
    }
}
