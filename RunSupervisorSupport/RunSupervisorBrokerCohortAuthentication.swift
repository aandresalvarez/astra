import ASTRACore
import Foundation
import RunBrokerClient

package struct RunSupervisorBrokerCodeIdentityTranscript: Codable, Sendable {
    let identifier: String
    let teamIdentifier: String?
    let cdHash: Data
}

package struct RunSupervisorBrokerCohortTranscript: Codable, Sendable {
    let domain: String
    let schemaVersion: Int
    let protocolVersion: UInt16
    let executionID: RunBrokerExecutionID
    let nonce: UUID
    let issuedAtMilliseconds: Int64
    let action: RunSupervisorControlAction
    let executionAuthentication: String
    let peerIdentity: RunSupervisorBrokerCodeIdentityTranscript
}

public enum RunSupervisorBrokerCohortAuthentication {
    public static func binding(
        request: RunSupervisorControlRequest,
        peerIdentity: DarwinProcessCodeIdentity,
        capability: RunBrokerCapabilitySecret
    ) throws -> RunSupervisorControlRequest {
        let transcript = try transcript(request: request, peerIdentity: peerIdentity)
        let code = capability.authenticationCode(for: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
        return request.bindingBrokerCohortAuthentication(code)
    }

    public static func verify(
        request: RunSupervisorControlRequest,
        peerIdentity: DarwinProcessCodeIdentity,
        capability: RunBrokerCapabilitySecret
    ) -> Bool {
        guard let claimed = request.brokerCohortAuthentication,
              let claimedData = Data(hexString: claimed),
              let transcript = try? transcript(request: request, peerIdentity: peerIdentity) else {
            return false
        }
        return capability.verifies(authenticationCode: claimedData, for: transcript)
    }

    private static func transcript(
        request: RunSupervisorControlRequest,
        peerIdentity: DarwinProcessCodeIdentity
    ) throws -> Data {
        try RunSupervisorDigests.canonicalData(RunSupervisorBrokerCohortTranscript(
            domain: "astra.run-supervisor.broker-cohort.v1",
            schemaVersion: request.schemaVersion,
            protocolVersion: request.protocolVersion,
            executionID: request.executionID,
            nonce: request.nonce,
            issuedAtMilliseconds: request.issuedAtMilliseconds,
            action: request.action,
            executionAuthentication: request.authentication,
            peerIdentity: .init(
                identifier: peerIdentity.identifier,
                teamIdentifier: peerIdentity.teamIdentifier,
                cdHash: peerIdentity.cdHash
            )
        ))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
