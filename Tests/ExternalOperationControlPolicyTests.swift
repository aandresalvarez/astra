import Foundation
import Testing
import ASTRACore

@Suite("External operation control policy")
struct ExternalOperationControlPolicyTests {
    @Test("Owned local supervisor is observable and cancellable for every provider runtime")
    func localSupervisorIsProviderNeutral() throws {
        let runtimes: [AgentRuntimeID] = [
            .claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .codexCLI,
            .cursorCLI,
            .openCodeCLI,
        ]

        for runtime in runtimes {
            let context = try makeContext(
                kind: .localRunSupervisor,
                instanceID: "supervisor:\(runtime.rawValue)",
                ownership: .authenticatedExecutionScoped,
                capabilities: [.observe, .cancel]
            )
            let result = ExternalOperationControlPolicy.assess(
                target: context.target,
                binding: context.binding
            )

            #expect(result.observation == .init(
                kind: .allowed,
                reason: .observationCapabilityVerified
            ))
            #expect(result.cancellation == .init(
                kind: .allowed,
                reason: .authenticatedCancellationHandleVerified
            ))
        }
    }

    @Test("ASTRA-managed Docker job requires the authenticated scoped handle")
    func managedDockerJobIsCancellableOnlyWhenOwned() throws {
        let owned = try makeContext(
            kind: .managedDockerJob,
            instanceID: "docker_workspace_job:task:run:job",
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe, .cancel]
        )
        let allowed = ExternalOperationControlPolicy.assess(
            target: owned.target,
            binding: owned.binding
        )
        #expect(allowed.cancellation.kind == .allowed)

        let imported = ExternalOperationControlBinding(
            executionID: owned.binding.executionID,
            authority: owned.binding.authority,
            backendIdentity: owned.binding.backendIdentity,
            ownership: .imported,
            declaredCapabilities: [.observe, .cancel]
        )
        let blocked = ExternalOperationControlPolicy.assess(
            target: owned.target,
            binding: imported
        )
        #expect(blocked.cancellation == .init(
            kind: .blocked,
            reason: .authenticatedOwnershipMissing
        ))
    }

    @Test("SSH imported and opaque operations are monitoring-only")
    func initialMonitoringOnlyBackends() throws {
        let backends: [(
            ExternalOperationBackendKindID,
            ExternalOperationControlOwnership,
            ExternalOperationControlDecisionReason
        )] = [
            (.sshRemoteOperation, .opaque, .sshRequiresReviewedRemoteHelper),
            (.importedOperation, .imported, .importedOperationIsMonitoringOnly),
            (.opaqueOperation, .opaque, .opaqueOperationIsMonitoringOnly),
        ]

        for (kind, ownership, reason) in backends {
            let context = try makeContext(
                kind: kind,
                ownership: ownership,
                capabilities: .monitoringOnly
            )
            let result = ExternalOperationControlPolicy.assess(
                target: context.target,
                binding: context.binding
            )

            #expect(result.observation.kind == .allowed)
            #expect(result.cancellation == .init(kind: .monitoringOnly, reason: reason))
        }
    }

    @Test("Observation and cancellation capabilities are not inferred from each other")
    func capabilitiesAreIndependent() throws {
        let cancellationOnly = try makeContext(
            kind: .localRunSupervisor,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.cancel]
        )
        let cancellationOnlyResult = ExternalOperationControlPolicy.assess(
            target: cancellationOnly.target,
            binding: cancellationOnly.binding
        )
        #expect(cancellationOnlyResult.observation == .init(
            kind: .blocked,
            reason: .observationCapabilityMissing
        ))
        #expect(cancellationOnlyResult.cancellation.kind == .allowed)

        let observationOnly = try makeContext(
            kind: .localRunSupervisor,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe]
        )
        let observationOnlyResult = ExternalOperationControlPolicy.assess(
            target: observationOnly.target,
            binding: observationOnly.binding
        )
        #expect(observationOnlyResult.observation.kind == .allowed)
        #expect(observationOnlyResult.cancellation == .init(
            kind: .blocked,
            reason: .cancellationCapabilityMissing
        ))
    }

    @Test("Monitoring-only backends cannot overclaim cancellation")
    func cancellationCapabilityOverclaimFailsClosed() throws {
        let context = try makeContext(
            kind: .sshRemoteOperation,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe, .cancel]
        )
        let result = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding
        )

        #expect(result.observation.kind == .allowed)
        #expect(result.cancellation == .init(
            kind: .blocked,
            reason: .cancellationCapabilityOverclaim
        ))
    }

    @Test("Unknown capability bits fail closed for both operations")
    func unknownCapabilitiesFailClosed() throws {
        let context = try makeContext(
            kind: .localRunSupervisor,
            ownership: .authenticatedExecutionScoped,
            capabilities: .init(rawValue: 1 << 7)
        )
        let result = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding
        )

        #expect(result.observation == .init(
            kind: .blocked,
            reason: .unsupportedCapabilityDeclaration
        ))
        #expect(result.cancellation == result.observation)
    }

    @Test("A future backend can be observed but cannot acquire cancellation by declaration")
    func unknownFutureBackendFailsClosedForCancellation() throws {
        let futureKind = try #require(ExternalOperationBackendKindID(rawValue: "future_backend"))
        let context = try makeContext(
            kind: futureKind,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe, .cancel]
        )
        let result = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding
        )

        #expect(result.observation.kind == .allowed)
        #expect(result.cancellation == .init(
            kind: .blocked,
            reason: .unsupportedBackend
        ))
    }

    @Test("Execution authority and backend identity must match exactly")
    func staleControlTargetsFailClosed() throws {
        let context = try makeContext(
            kind: .localRunSupervisor,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe, .cancel]
        )
        let otherIdentity = try ExternalOperationBackendIdentity(
            kind: .localRunSupervisor,
            instanceID: "supervisor:other"
        )
        let staleTargets: [(ExternalOperationControlTarget, ExternalOperationControlDecisionReason)] = [
            (
                .init(
                    executionID: RunBrokerExecutionID(rawValue: fixedUUID(21)),
                    authority: context.target.authority,
                    backendIdentity: context.target.backendIdentity
                ),
                .staleExecution
            ),
            (
                .init(
                    executionID: context.target.executionID,
                    authority: .init(
                        id: context.target.authority.id,
                        epoch: .init(rawValue: context.target.authority.epoch.rawValue + 1)
                    ),
                    backendIdentity: context.target.backendIdentity
                ),
                .staleAuthority
            ),
            (
                .init(
                    executionID: context.target.executionID,
                    authority: context.target.authority,
                    backendIdentity: otherIdentity
                ),
                .staleBackendIdentity
            ),
        ]

        for (target, reason) in staleTargets {
            let result = ExternalOperationControlPolicy.assess(
                target: target,
                binding: context.binding
            )
            #expect(result.observation == .init(kind: .blocked, reason: reason))
            #expect(result.cancellation == result.observation)
        }
    }

    @Test("Wire contracts round-trip exact identity and reject version drift or PID fields")
    func strictVersionedWireContracts() throws {
        let context = try makeContext(
            kind: .managedDockerJob,
            ownership: .authenticatedExecutionScoped,
            capabilities: [.observe, .cancel]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bindingData = try encoder.encode(context.binding)
        let targetData = try encoder.encode(context.target)

        #expect(try JSONDecoder().decode(
            ExternalOperationControlBinding.self,
            from: bindingData
        ) == context.binding)
        #expect(try JSONDecoder().decode(
            ExternalOperationControlTarget.self,
            from: targetData
        ) == context.target)

        var unsupportedVersion = try #require(
            JSONSerialization.jsonObject(with: bindingData) as? [String: Any]
        )
        unsupportedVersion["schemaVersion"] = ExternalOperationControlBinding.currentSchemaVersion + 1
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExternalOperationControlBinding.self,
                from: JSONSerialization.data(withJSONObject: unsupportedVersion)
            )
        }

        var pidTarget = try #require(
            JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        )
        pidTarget["pid"] = 42
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExternalOperationControlTarget.self,
                from: JSONSerialization.data(withJSONObject: pidTarget)
            )
        }

        var unknownTopLevel = unsupportedVersion
        unknownTopLevel["schemaVersion"] = ExternalOperationControlBinding.currentSchemaVersion
        unknownTopLevel["fallbackBackend"] = "local_run_supervisor"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExternalOperationControlBinding.self,
                from: JSONSerialization.data(withJSONObject: unknownTopLevel)
            )
        }
    }

    @Test("Backend identifiers are canonical and bounded")
    func backendIdentifiersRejectAmbiguity() throws {
        #expect(ExternalOperationBackendKindID(rawValue: " SSH ") == nil)
        #expect(ExternalOperationBackendKindID(rawValue: "ssh-remote") == nil)
        #expect(throws: ExternalOperationControlContractError.invalidBackendInstanceID) {
            try ExternalOperationBackendIdentity(
                kind: .sshRemoteOperation,
                instanceID: " host with spaces "
            )
        }
    }
}

private struct ExternalOperationControlTestContext {
    let target: ExternalOperationControlTarget
    let binding: ExternalOperationControlBinding
}

private func makeContext(
    kind: ExternalOperationBackendKindID,
    instanceID: String = "backend:instance-1",
    ownership: ExternalOperationControlOwnership,
    capabilities: ExternalOperationBackendCapabilities
) throws -> ExternalOperationControlTestContext {
    let executionID = RunBrokerExecutionID(rawValue: fixedUUID(1))
    let authority = RunBrokerAuthority(
        id: RunBrokerAuthorityID(rawValue: fixedUUID(2)),
        epoch: .init(rawValue: 7)
    )
    let backendIdentity = try ExternalOperationBackendIdentity(
        kind: kind,
        instanceID: instanceID
    )
    return .init(
        target: .init(
            executionID: executionID,
            authority: authority,
            backendIdentity: backendIdentity
        ),
        binding: .init(
            executionID: executionID,
            authority: authority,
            backendIdentity: backendIdentity,
            ownership: ownership,
            declaredCapabilities: capabilities
        )
    )
}

private func fixedUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, value
    ))
}
