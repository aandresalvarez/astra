import Foundation
import Testing
@testable import ASTRACore

@Suite("External operation control policy")
struct ExternalOperationControlPolicyTests {
    @Test("Decoded matching descriptor remains unverified until the trusted boundary authenticates it")
    func decodedDescriptorCannotSelfAttestOwnership() throws {
        let context = try makeSupervisorContext()
        let decodedBinding = try JSONDecoder().decode(
            ExternalOperationControlBinding.self,
            from: JSONEncoder().encode(context.binding)
        )
        let decodedTarget = try JSONDecoder().decode(
            ExternalOperationControlTarget.self,
            from: JSONEncoder().encode(context.target)
        )

        let forged = ExternalOperationControlPolicy.assess(
            target: decodedTarget,
            binding: decodedBinding,
            cancellationIntent: .immediate
        )
        #expect(forged.observation.kind == .allowed)
        #expect(forged.cancellation == .init(
            kind: .blocked,
            reason: .unverifiedProvenance
        ))

        let evidence = try verifiedEvidence(for: context)
        #expect(!((evidence as Any) is any Encodable))
        let verified = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding,
            cancellationIntent: .immediate,
            verifiedEvidence: evidence
        )
        #expect(verified.cancellation == .init(
            kind: .allowed,
            reason: .verifiedImmediateTermination,
            auditRequirement: .immediateTermination
        ))

        let wire = String(decoding: try JSONEncoder().encode(context.binding), as: UTF8.self)
        #expect(!wire.contains("ownership"))
        #expect(!wire.contains("provenance"))
        #expect(!wire.contains("authenticated"))
    }

    @Test("Immediate supervisor termination is provider-neutral and explicitly audited")
    func supervisorImmediateTerminationCoversEveryRuntime() throws {
        let runtimes: [AgentRuntimeID] = [
            .claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .codexCLI,
            .cursorCLI,
            .openCodeCLI,
        ]

        for (offset, runtime) in runtimes.enumerated() {
            let context = try makeSupervisorContext(seed: UInt8(offset + 1))
            let result = ExternalOperationControlPolicy.assess(
                target: context.target,
                binding: context.binding,
                cancellationIntent: .immediate,
                verifiedEvidence: try verifiedEvidence(for: context)
            )

            #expect(result.cancellationIntent == .immediate)
            #expect(result.cancellation.kind == .allowed, "runtime: \(runtime.rawValue)")
            #expect(result.cancellation.auditRequirement == .immediateTermination)
        }
    }

    @Test("Unsupported graceful request is blocked and never escalated to immediate")
    func gracefulAndImmediateCapabilitiesStaySeparate() throws {
        let immediateOnly = try makeSupervisorContext(
            capabilities: [.observe, .immediateTermination]
        )
        let evidence = try verifiedEvidence(for: immediateOnly)
        let graceful = ExternalOperationControlPolicy.assess(
            target: immediateOnly.target,
            binding: immediateOnly.binding,
            cancellationIntent: .graceful,
            verifiedEvidence: evidence
        )
        #expect(graceful.cancellationIntent == .graceful)
        #expect(graceful.cancellation == .init(
            kind: .blocked,
            reason: .gracefulCancellationCapabilityMissing
        ))
        #expect(graceful.cancellation.auditRequirement == .none)

        let immediate = ExternalOperationControlPolicy.assess(
            target: immediateOnly.target,
            binding: immediateOnly.binding,
            cancellationIntent: .immediate,
            verifiedEvidence: evidence
        )
        #expect(immediate.cancellation.kind == .allowed)
        #expect(immediate.cancellation.reason == .verifiedImmediateTermination)

        let gracefulContext = try makeSupervisorContext(
            seed: 11,
            capabilities: [.observe, .gracefulCancellation]
        )
        let supportedGraceful = ExternalOperationControlPolicy.assess(
            target: gracefulContext.target,
            binding: gracefulContext.binding,
            cancellationIntent: .graceful,
            verifiedEvidence: try verifiedEvidence(for: gracefulContext)
        )
        #expect(supportedGraceful.cancellation == .init(
            kind: .allowed,
            reason: .verifiedGracefulCancellation
        ))
    }

    @Test("Managed Docker remains monitoring-only and destructive capability claims are rejected")
    func managedDockerIsNotFirstClassCancellation() throws {
        let monitored = try makeMonitoringContext(kind: .managedDockerJob)
        let result = ExternalOperationControlPolicy.assess(
            target: monitored.target,
            binding: monitored.binding,
            cancellationIntent: .immediate
        )
        #expect(result.observation.kind == .allowed)
        #expect(result.cancellation == .init(
            kind: .monitoringOnly,
            reason: .managedDockerPendingAuthenticatedControl
        ))

        for destructiveCapability in [
            ExternalOperationControlCapabilities.gracefulCancellation,
            .immediateTermination,
        ] {
            let overclaim = try makeMonitoringContext(
                kind: .managedDockerJob,
                capabilities: [.observe, destructiveCapability]
            )
            let blocked = ExternalOperationControlPolicy.assess(
                target: overclaim.target,
                binding: overclaim.binding,
                cancellationIntent: .immediate
            )
            #expect(blocked.observation.kind == .allowed)
            #expect(blocked.cancellation == .init(
                kind: .blocked,
                reason: .cancellationCapabilityOverclaim
            ))
        }
    }

    @Test("SSH imported and opaque operations are monitoring-only")
    func otherMonitoringOnlyBackends() throws {
        let backends: [(
            ExternalOperationBackendKindID,
            ExternalOperationControlDecisionReason
        )] = [
            (.sshRemoteOperation, .sshRequiresReviewedRemoteHelper),
            (.importedOperation, .importedOperationIsMonitoringOnly),
            (.opaqueOperation, .opaqueOperationIsMonitoringOnly),
        ]

        for (kind, reason) in backends {
            let context = try makeMonitoringContext(kind: kind)
            let result = ExternalOperationControlPolicy.assess(
                target: context.target,
                binding: context.binding,
                cancellationIntent: .graceful
            )
            #expect(result.observation.kind == .allowed)
            #expect(result.cancellation == .init(kind: .monitoringOnly, reason: reason))
        }
    }

    @Test("Observation and immediate termination remain independent")
    func observationAndTerminationAreIndependent() throws {
        let immediateOnly = try makeSupervisorContext(capabilities: [.immediateTermination])
        let immediateResult = ExternalOperationControlPolicy.assess(
            target: immediateOnly.target,
            binding: immediateOnly.binding,
            cancellationIntent: .immediate,
            verifiedEvidence: try verifiedEvidence(for: immediateOnly)
        )
        #expect(immediateResult.observation == .init(
            kind: .blocked,
            reason: .observationCapabilityMissing
        ))
        #expect(immediateResult.cancellation.kind == .allowed)

        let observationOnly = try makeSupervisorContext(capabilities: [.observe])
        let observationResult = ExternalOperationControlPolicy.assess(
            target: observationOnly.target,
            binding: observationOnly.binding,
            cancellationIntent: .immediate,
            verifiedEvidence: try verifiedEvidence(for: observationOnly)
        )
        #expect(observationResult.observation.kind == .allowed)
        #expect(observationResult.cancellation == .init(
            kind: .blocked,
            reason: .immediateTerminationCapabilityMissing
        ))
    }

    @Test("Unknown capability bits fail closed for observation and cancellation")
    func unknownCapabilitiesFailClosed() throws {
        let context = try makeSupervisorContext(capabilities: .init(rawValue: 1 << 7))
        let result = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding,
            cancellationIntent: .immediate
        )
        #expect(result.observation == .init(
            kind: .blocked,
            reason: .unsupportedCapabilityDeclaration
        ))
        #expect(result.cancellation == result.observation)
    }

    @Test("Future backend observation may remain available but cancellation is blocked")
    func futureBackendFailsClosedForCancellation() throws {
        let kind = try #require(ExternalOperationBackendKindID(rawValue: "future_backend"))
        let context = try makeMonitoringContext(
            kind: kind,
            capabilities: [.observe, .immediateTermination]
        )
        let result = ExternalOperationControlPolicy.assess(
            target: context.target,
            binding: context.binding,
            cancellationIntent: .immediate
        )
        #expect(result.observation.kind == .allowed)
        #expect(result.cancellation == .init(kind: .blocked, reason: .unsupportedBackend))
    }

    @Test("Execution authority backend and embedded supervisor identity must match exactly")
    func staleControlTargetsFailClosed() throws {
        let context = try makeSupervisorContext()
        let other = try makeSupervisorContext(seed: 31)
        let staleTargets: [(ExternalOperationControlTarget, ExternalOperationControlDecisionReason)] = [
            (
                .init(
                    executionID: other.target.executionID,
                    authority: context.target.authority,
                    backendIdentity: context.target.backendIdentity
                ),
                .staleExecution
            ),
            (
                .init(
                    executionID: context.target.executionID,
                    authority: other.target.authority,
                    backendIdentity: context.target.backendIdentity
                ),
                .staleAuthority
            ),
            (
                .init(
                    executionID: context.target.executionID,
                    authority: context.target.authority,
                    backendIdentity: other.target.backendIdentity
                ),
                .staleBackendIdentity
            ),
        ]
        for (target, reason) in staleTargets {
            let result = ExternalOperationControlPolicy.assess(
                target: target,
                binding: context.binding,
                cancellationIntent: .immediate
            )
            #expect(result.observation == .init(kind: .blocked, reason: reason))
            #expect(result.cancellation == result.observation)
        }

        let mismatchedSupervisor = try ExternalOperationSupervisorIdentity(
            installationID: installationID(1),
            storeID: storeID(2),
            executionID: executionID(90),
            authority: context.binding.authority
        )
        let mismatchedIdentity = ExternalOperationBackendIdentity(
            supervisorIdentity: mismatchedSupervisor
        )
        let mismatchedBinding = ExternalOperationControlBinding(
            executionID: context.binding.executionID,
            authority: context.binding.authority,
            backendIdentity: mismatchedIdentity,
            declaredCapabilities: [.observe, .immediateTermination]
        )
        let mismatchedTarget = ExternalOperationControlTarget(
            executionID: mismatchedBinding.executionID,
            authority: mismatchedBinding.authority,
            backendIdentity: mismatchedIdentity
        )
        let result = ExternalOperationControlPolicy.assess(
            target: mismatchedTarget,
            binding: mismatchedBinding,
            cancellationIntent: .immediate
        )
        #expect(result.observation.kind == .allowed)
        #expect(result.cancellation == .init(
            kind: .blocked,
            reason: .staleSupervisorIdentity
        ))
    }

    @Test("Supervisor aliases and incomplete identities cannot enter the wire contract")
    func supervisorIdentityCannotBeReplacedByAlias() throws {
        #expect(throws: ExternalOperationControlContractError.supervisorIdentityRequired) {
            try ExternalOperationBackendIdentity(
                monitoringKind: .localRunSupervisor,
                instanceID: "supervisor:alias"
            )
        }

        let context = try makeSupervisorContext()
        let targetData = try JSONEncoder().encode(context.target)
        var aliasTarget = try #require(
            JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        )
        aliasTarget["backendIdentity"] = [
            "kind": ExternalOperationBackendKindID.localRunSupervisor.rawValue,
            "instanceID": "supervisor:alias",
        ]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExternalOperationControlTarget.self,
                from: JSONSerialization.data(withJSONObject: aliasTarget)
            )
        }

        for missingField in ["installationID", "storeID"] {
            var incomplete = try #require(
                JSONSerialization.jsonObject(with: targetData) as? [String: Any]
            )
            var backend = try #require(incomplete["backendIdentity"] as? [String: Any])
            var supervisor = try #require(backend["supervisorIdentity"] as? [String: Any])
            supervisor.removeValue(forKey: missingField)
            backend["supervisorIdentity"] = supervisor
            incomplete["backendIdentity"] = backend
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    ExternalOperationControlTarget.self,
                    from: JSONSerialization.data(withJSONObject: incomplete)
                )
            }
        }
    }

    @Test("Wire contracts reject version drift PID authority and fallback fields")
    func strictVersionedWireContracts() throws {
        let context = try makeSupervisorContext()
        let bindingData = try JSONEncoder().encode(context.binding)
        let targetData = try JSONEncoder().encode(context.target)
        #expect(try JSONDecoder().decode(
            ExternalOperationControlBinding.self,
            from: bindingData
        ) == context.binding)
        #expect(try JSONDecoder().decode(
            ExternalOperationControlTarget.self,
            from: targetData
        ) == context.target)

        var unsupported = try #require(
            JSONSerialization.jsonObject(with: bindingData) as? [String: Any]
        )
        unsupported["schemaVersion"] = ExternalOperationControlBinding.currentSchemaVersion + 1
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExternalOperationControlBinding.self,
                from: JSONSerialization.data(withJSONObject: unsupported)
            )
        }

        for forbiddenField in ["pid", "ownership", "fallbackBackend"] {
            var forbidden = try #require(
                JSONSerialization.jsonObject(with: targetData) as? [String: Any]
            )
            forbidden[forbiddenField] = forbiddenField == "pid" ? 42 : "forged"
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    ExternalOperationControlTarget.self,
                    from: JSONSerialization.data(withJSONObject: forbidden)
                )
            }
        }
    }

    @Test("Verifier refuses mismatched descriptors and monitoring backends")
    func verifierBoundaryFailsClosed() throws {
        let context = try makeSupervisorContext()
        let other = try makeSupervisorContext(seed: 41)
        #expect(throws: ExternalOperationControlVerificationError.descriptorMismatch) {
            try ExternalOperationControlProvenanceVerifier.verify(
                target: other.target,
                binding: context.binding,
                authenticator: ExpectedSupervisorAuthenticator(
                    identity: try #require(context.binding.backendIdentity.supervisorIdentity)
                )
            )
        }

        let docker = try makeMonitoringContext(kind: .managedDockerJob)
        #expect(throws: ExternalOperationControlVerificationError.unsupportedBackend) {
            try ExternalOperationControlProvenanceVerifier.verify(
                target: docker.target,
                binding: docker.binding,
                authenticator: ExpectedSupervisorAuthenticator(
                    identity: try #require(context.binding.backendIdentity.supervisorIdentity)
                )
            )
        }
    }
}

private struct ExternalOperationControlTestContext {
    let target: ExternalOperationControlTarget
    let binding: ExternalOperationControlBinding
}

private enum TestAuthenticatorError: Error {
    case identityMismatch
}

private struct ExpectedSupervisorAuthenticator: ExternalOperationControlProvenanceAuthenticating {
    let identity: ExternalOperationSupervisorIdentity

    func authenticate(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) throws {
        guard target.backendIdentity.supervisorIdentity == identity,
              binding.backendIdentity.supervisorIdentity == identity else {
            throw TestAuthenticatorError.identityMismatch
        }
    }
}

private func verifiedEvidence(
    for context: ExternalOperationControlTestContext
) throws -> ExternalOperationVerifiedEvidence {
    let identity = try #require(context.binding.backendIdentity.supervisorIdentity)
    return try ExternalOperationControlProvenanceVerifier.verify(
        target: context.target,
        binding: context.binding,
        authenticator: ExpectedSupervisorAuthenticator(identity: identity)
    )
}

private func makeSupervisorContext(
    seed: UInt8 = 1,
    capabilities: ExternalOperationControlCapabilities = [.observe, .immediateTermination]
) throws -> ExternalOperationControlTestContext {
    let executionID = executionID(seed)
    let authority = RunBrokerAuthority(
        id: authorityID(seed &+ 1),
        epoch: .init(rawValue: 7)
    )
    let supervisorIdentity = try ExternalOperationSupervisorIdentity(
        installationID: installationID(seed &+ 2),
        storeID: storeID(seed &+ 3),
        executionID: executionID,
        authority: authority
    )
    return makeContext(
        executionID: executionID,
        authority: authority,
        backendIdentity: .init(supervisorIdentity: supervisorIdentity),
        capabilities: capabilities
    )
}

private func makeMonitoringContext(
    kind: ExternalOperationBackendKindID,
    capabilities: ExternalOperationControlCapabilities = .monitoringOnly
) throws -> ExternalOperationControlTestContext {
    let executionID = executionID(61)
    let authority = RunBrokerAuthority(id: authorityID(62), epoch: .init(rawValue: 3))
    return makeContext(
        executionID: executionID,
        authority: authority,
        backendIdentity: try .init(
            monitoringKind: kind,
            instanceID: "backend:instance-1"
        ),
        capabilities: capabilities
    )
}

private func makeContext(
    executionID: RunBrokerExecutionID,
    authority: RunBrokerAuthority,
    backendIdentity: ExternalOperationBackendIdentity,
    capabilities: ExternalOperationControlCapabilities
) -> ExternalOperationControlTestContext {
    .init(
        target: .init(
            executionID: executionID,
            authority: authority,
            backendIdentity: backendIdentity
        ),
        binding: .init(
            executionID: executionID,
            authority: authority,
            backendIdentity: backendIdentity,
            declaredCapabilities: capabilities
        )
    )
}

private func installationID(_ value: UInt8) -> RunBrokerInstallationID {
    .init(rawValue: fixedUUID(value))
}

private func storeID(_ value: UInt8) -> RunBrokerStoreID {
    .init(rawValue: fixedUUID(value))
}

private func executionID(_ value: UInt8) -> RunBrokerExecutionID {
    .init(rawValue: fixedUUID(value))
}

private func authorityID(_ value: UInt8) -> RunBrokerAuthorityID {
    .init(rawValue: fixedUUID(value))
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
