import CryptoKit
import Foundation

/// Deterministic broker authority derivation over authority-free launch truth.
/// Callers can predict an ID, but only the broker/ledger admission boundaries
/// can persist it as execution authority.
public enum RunBrokerAuthorityDerivation {
    public static func initialLaunch(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        admissionID: UUID,
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        configuration: ExecutionLaunchConfigurationSnapshot,
        declaredEffects: [ExecutionEffectClaim],
        supervisionPolicy: ExecutionSupervisionPolicySnapshot,
        createdAt: Date
    ) throws -> RunBrokerAuthority {
        try derive(
            domain: "initial-launch",
            installationID: installationID,
            storeID: storeID,
            mutationID: admissionID,
            executionID: executionID,
            taskID: taskID,
            configuration: configuration,
            declaredEffects: declaredEffects,
            supervisionPolicy: supervisionPolicy,
            createdAt: createdAt
        )
    }

    public static func runtimeSwitchTarget(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        requestID: RuntimeSwitchRequestID,
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        configuration: ExecutionLaunchConfigurationSnapshot,
        declaredEffects: [ExecutionEffectClaim],
        supervisionPolicy: ExecutionSupervisionPolicySnapshot,
        createdAt: Date
    ) throws -> RunBrokerAuthority {
        try derive(
            domain: "runtime-switch-target",
            installationID: installationID,
            storeID: storeID,
            mutationID: requestID.rawValue,
            executionID: executionID,
            taskID: taskID,
            configuration: configuration,
            declaredEffects: declaredEffects,
            supervisionPolicy: supervisionPolicy,
            createdAt: createdAt
        )
    }

    private static func derive(
        domain: String,
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        mutationID: UUID,
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        configuration: ExecutionLaunchConfigurationSnapshot,
        declaredEffects: [ExecutionEffectClaim],
        supervisionPolicy: ExecutionSupervisionPolicySnapshot,
        createdAt: Date
    ) throws -> RunBrokerAuthority {
        let material = AuthorityFreeLaunchMaterial(
            domain: "astra.run-broker.authority.v1.\(domain)",
            installationID: installationID,
            storeID: storeID,
            mutationID: mutationID,
            executionID: executionID,
            taskID: taskID,
            configuration: configuration,
            declaredEffects: declaredEffects,
            supervisionPolicy: supervisionPolicy,
            createdAt: createdAt
        )
        let bytes = Array(SHA256.hash(data: try ASTRACanonicalJSON.encode(material)).prefix(16))
        return .init(
            id: .init(rawValue: UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))),
            epoch: .initial
        )
    }
}

private struct AuthorityFreeLaunchMaterial: Encodable {
    let domain: String
    let installationID: RunBrokerInstallationID
    let storeID: RunBrokerStoreID
    let mutationID: UUID
    let executionID: RunBrokerExecutionID
    let taskID: UUID
    let configuration: ExecutionLaunchConfigurationSnapshot
    let declaredEffects: [ExecutionEffectClaim]
    let supervisionPolicy: ExecutionSupervisionPolicySnapshot
    let createdAt: Date
}
