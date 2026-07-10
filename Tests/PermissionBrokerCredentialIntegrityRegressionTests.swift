import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Permission broker credential integrity")
struct PermissionBrokerCredentialIntegrityRegressionTests {
    @Test("Credential approval grants are derived from the approved request")
    func credentialApprovalGrantsComeFromRequest() throws {
        let connectorID = UUID()
        let requestedLabel = "connector:\(connectorID.uuidString):JIRA_API_TOKEN"
        let injectedLabel = "connector:\(UUID().uuidString):OTHER_API_TOKEN"
        let request = PermissionRequest.connectorCredentials(
            connectorID: connectorID,
            displayName: "Jira connector credential",
            labels: [requestedLabel]
        )
        let payload = PermissionApprovalEventPayload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            request: request,
            decision: .askUser(
                message: "Approve the Jira connector credential",
                grants: [.credential(label: injectedLabel)]
            ),
            grants: [.credential(label: injectedLabel)],
            displayMessage: "Approve the Jira connector credential"
        )
        let encoded = try #require(payload.encodedString())
        let newlyCreatedPayload = PermissionBroker.approvalPayload(
            providerID: .claudeCode,
            request: request,
            reason: "Connector credential egress requires approval.",
            grants: [.credential(label: injectedLabel)]
        )

        #expect(PermissionBroker.structuredApprovalGrants(from: encoded) == [
            .credential(label: requestedLabel)
        ])
        #expect(newlyCreatedPayload.grants == [.credential(label: requestedLabel)])
    }
}
