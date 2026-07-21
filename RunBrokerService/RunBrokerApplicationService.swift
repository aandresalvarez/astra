import ASTRACore
import ASTRARunLedger
import CryptoKit
import Foundation
import RunBrokerKit
import RunSupervisorSupport

/// Sole application composition boundary. It owns one canonical ledger and
/// delegates all provider effects to the durable orchestrator. Endpoint-level
/// response caching is deliberately irrelevant to mutations: replay safety is
/// provided by ledger event IDs, admission IDs, and exact outbox cursors.
public final class RunBrokerApplicationService: RunBrokerApplicationCommandHandling, @unchecked Sendable {
    private let ledger: RunLedger
    private let orchestrator: RunBrokerOrchestrator
    private let outbox: RunBrokerProjectionOutbox
    private let vault: any RunBrokerCapabilityVaulting
    private let runtimeSwitch: RunBrokerRuntimeSwitchService
    private let lock = NSRecursiveLock()
    private var runtimeSwitchWorker: RunBrokerRuntimeSwitchReconciliationWorker?

    public var supportsGracefulCancellation: Bool { runtimeSwitch.supportsGracefulHandoff }
    public var supportsImmediateTermination: Bool {
        orchestrator.supportsAuthenticatedImmediateTermination
    }

    public init(
        ledger: RunLedger,
        orchestrator: RunBrokerOrchestrator,
        vault: any RunBrokerCapabilityVaulting
    ) {
        self.ledger = ledger
        self.orchestrator = orchestrator
        self.outbox = RunBrokerProjectionOutbox(ledger: ledger)
        self.vault = vault
        self.runtimeSwitch = .init(
            ledger: ledger,
            vault: vault,
            orchestrator: orchestrator,
            backend: UnavailableRunBrokerRuntimeSwitchBackend()
        )
    }

    /// Activates broker-owned startup recovery and pending-transition retries.
    /// App/client targets cannot construct or drive the worker.
    public func startRuntimeSwitchReconciliation(
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        let worker = lock.withLock { () -> RunBrokerRuntimeSwitchReconciliationWorker in
            if let runtimeSwitchWorker { return runtimeSwitchWorker }
            let worker = RunBrokerRuntimeSwitchReconciliationWorker(
                service: runtimeSwitch,
                logger: logger
            )
            runtimeSwitchWorker = worker
            return worker
        }
        worker.start()
    }

    /// Bounded broker-local diagnostic state; safe for a future health surface
    /// because it contains no request payloads, paths, or capability material.
    func runtimeSwitchReconciliationHealth() -> RunBrokerRuntimeSwitchWorkerHealth {
        lock.withLock {
            runtimeSwitchWorker?.healthSnapshot() ?? .init(
                state: .stopped,
                consecutiveFailures: 0,
                lastErrorType: nil,
                lastFailureAt: nil
            )
        }
    }

    /// Internal test/composition seam; not exported to ASTRA or clients.
    init(
        ledger: RunLedger,
        orchestrator: RunBrokerOrchestrator,
        vault: any RunBrokerCapabilityVaulting,
        runtimeSwitchBackend: any RunBrokerRuntimeSwitchBackend
    ) {
        self.ledger = ledger
        self.orchestrator = orchestrator
        self.outbox = RunBrokerProjectionOutbox(ledger: ledger)
        self.vault = vault
        self.runtimeSwitch = .init(
            ledger: ledger,
            vault: vault,
            orchestrator: orchestrator,
            backend: runtimeSwitchBackend
        )
    }

    public func handle(
        _ command: RunBrokerApplicationCommand,
        idempotencyKey: UUID,
        now: Date
    ) throws -> RunBrokerApplicationResponse {
        try lock.withLock {
            switch command {
            case .brokerContext:
                // A context response advertises durable typed delivery; a
                // corrupt or drifted ledger must fail the endpoint here, not
                // admit new work whose delivery dies later at the damaged row.
                let health = ledger.verifyHealth()
                guard health.status == .healthy else {
                    throw RunBrokerApplicationEndpointError.requestRejected
                }
                var features: RunBrokerRuntimeFeatureSet = [.durableTypedStream]
                if runtimeSwitch.supportsGracefulHandoff {
                    features.insert([.gracefulCancellation, .safeRuntimeHandoff])
                }
                if runtimeSwitch.supportsImmediateTermination {
                    features.insert(.immediateTermination)
                }
                return .brokerContext(.init(
                    installationID: ledger.identity.installationID,
                    storeID: ledger.identity.storeID,
                    brokerProtocolVersion: .v2,
                    runtimeFeatures: features,
                    durableHeadSequence: health.lastEventSequence ?? 0
                ))

            case .start(let request):
                try request.validate(now: now)
                guard request.runtimeProtocol == .baseline else {
                    throw RunBrokerApplicationContractError.invalidManifestMetadata
                }
                let manifest = try mintLaunchManifest(
                    request.draft,
                    idempotencyKey: idempotencyKey
                )
                let outcome = try orchestrator.start(.init(
                    authorityMode: .durableBroker,
                    manifest: manifest,
                    primaryOperationID: request.primaryOperationID,
                    admissionID: idempotencyKey,
                    arguments: request.arguments,
                    environment: request.environment
                ))
                return .executionStatus(try status(
                    executionID: manifest.executionID,
                    reconciliation: outcome
                ))

            case .reconcile(let executionID):
                let outcome = try orchestrator.reconcile(executionID: executionID)
                return .executionStatus(try status(
                    executionID: executionID,
                    reconciliation: outcome
                ))

            case .executionStatus(let executionID):
                return .executionStatus(try status(executionID: executionID))

            case .nextProjectionMessage:
                return .projectionMessage(try outbox.next())

            case .projectionHandshake(let cursor):
                return .projectionHandshake(try outbox.handshake(cursor))

            case .acknowledgeProjection(let acknowledgement):
                do {
                    _ = try outbox.acknowledge(acknowledgement)
                    return .projectionAcknowledged
                } catch {
                    throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
                }

            case .externalOperation(let external):
                return .externalOperation(try handleExternalOperation(
                    external,
                    idempotencyKey: idempotencyKey,
                    now: now
                ))

            case .requestGracefulRuntimeSwitch(let submission):
                guard submission.mode == .graceful else {
                    throw RunBrokerApplicationContractError.invalidRuntimeSwitch
                }
                return .runtimeSwitchStatus(try runtimeSwitch.submit(submission, now: now))

            case .requestImmediateRuntimeSwitchChallenge(let submission):
                guard submission.mode == .immediate else {
                    throw RunBrokerApplicationContractError.invalidRuntimeSwitch
                }
                return .runtimeSwitchStatus(try runtimeSwitch.submit(submission, now: now))

            case .confirmImmediateRuntimeSwitch(let confirmation):
                return .runtimeSwitchStatus(try runtimeSwitch.confirmImmediate(
                    confirmation,
                    now: now
                ))

            case .runtimeSwitchStatus(let requestID, let digest):
                return .runtimeSwitchStatus(try runtimeSwitch.status(
                    requestID: requestID,
                    requestDigest: digest,
                    now: now
                ))

            case .stopMonitoring(let request):
                return .monitoring(try stopMonitoring(
                    request,
                    idempotencyKey: idempotencyKey,
                    now: now
                ))

            case .requestImmediateCancellationChallenge(let request):
                return .executionControl(try requestImmediateCancellationChallenge(
                    request,
                    idempotencyKey: idempotencyKey,
                    now: now
                ))

            case .confirmImmediateCancellation(let confirmation):
                return .executionControl(try confirmImmediateCancellation(
                    confirmation,
                    now: now
                ))

            case .cancelExecution, .writeStandardInput, .closeStandardInput:
                throw RunBrokerApplicationEndpointError.externalOperationBlocked
            }
        }
    }

    private func status(
        executionID: RunBrokerExecutionID,
        reconciliation: RunBrokerReconciliationOutcome? = nil
    ) throws -> RunBrokerApplicationExecutionStatus {
        _ = reconciliation
        return try outbox.executionStatus(executionID, projection: ledger.projection())
    }

    /// Mints the initial fencing authority from authenticated broker context,
    /// the exact authority-free draft, and the durable admission identity.
    /// This makes retries deterministic without accepting client authority.
    private func mintLaunchManifest(
        _ draft: RunBrokerApplicationLaunchDraft,
        idempotencyKey: UUID
    ) throws -> ExecutionLaunchManifest {
        let authority = try RunBrokerAuthorityDerivation.initialLaunch(
            installationID: ledger.identity.installationID,
            storeID: ledger.identity.storeID,
            admissionID: idempotencyKey,
            executionID: draft.executionID,
            taskID: draft.taskID,
            configuration: draft.configuration,
            declaredEffects: draft.declaredEffects,
            supervisionPolicy: draft.supervisionPolicy,
            createdAt: draft.createdAt
        )
        return .init(
            installationID: ledger.identity.installationID,
            storeID: ledger.identity.storeID,
            executionID: draft.executionID,
            taskID: draft.taskID,
            authority: authority,
            configuration: draft.configuration,
            declaredEffects: draft.declaredEffects,
            supervisionPolicy: draft.supervisionPolicy,
            createdAt: draft.createdAt
        )
    }

    private func stopMonitoring(
        _ request: RunBrokerApplicationStopMonitoring,
        idempotencyKey: UUID,
        now: Date
    ) throws -> RunBrokerApplicationMonitoringStatus {
        let projection = try ledger.projection()
        guard let operation = projection.operations[request.operationID],
              operation.record.authority == request.authority else {
            throw RunBrokerApplicationEndpointError.executionNotFound
        }
        let current = projection.monitorDeadlines[request.operationID]
        if let current {
            guard let expected = request.expectedDeadline,
                  expected.operationID == current.operationID,
                  expected.authority == current.authority,
                  expected.dueAt == current.dueAt,
                  expected.recordedAt == current.recordedAt,
                  expected.attempt == current.attempt,
                  expected.generation == current.generation else {
                throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
            }
            _ = try ledger.removeMonitorDeadline(
                expected: current,
                occurredAt: now,
                idempotencyKey: idempotencyKey
            )
        } else if request.expectedDeadline != nil {
            // A lost response retry is accepted only when the exact event ID
            // exists; otherwise a stale expected schedule is a conflict.
            guard try ledger.event(eventID: .init(rawValue: idempotencyKey)) != nil else {
                throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
            }
        }
        return .init(
            operationID: request.operationID,
            authority: request.authority,
            deadline: nil,
            stopped: true
        )
    }

    private func requestImmediateCancellationChallenge(
        _ request: RunBrokerApplicationImmediateCancellationRequest,
        idempotencyKey: UUID,
        now: Date
    ) throws -> RunBrokerApplicationExecutionControlStatus {
        guard supportsImmediateTermination else {
            throw RunBrokerApplicationEndpointError.externalOperationBlocked
        }
        // Force-challenge timestamps must be exactly millisecond-canonical;
        // the production server supplies a sub-millisecond Date().
        let now = Self.canonicalMilliseconds(now)
        let execution = try exactExecution(request.fence)
        try orchestrator.authenticateSupervisorProvenance(
            identity: .init(
                installationID: execution.manifest.installationID,
                storeID: execution.manifest.storeID,
                executionID: execution.manifest.executionID,
                authority: execution.authority
            ),
            expectedManifestSHA256: try RuntimeSwitchDigests.manifest(execution.manifest)
        )
        // Provenance reconciliation may have persisted spooled supervisor
        // events and advanced the fence; re-validate so a stale sequence is
        // rejected before a challenge is committed, not at confirmation.
        _ = try exactExecution(request.fence)
        let digest = try request.requestDigest()
        let current = try ledger.projection()
        let challenge: ExecutionForceChallenge
        if let challengeID = current.executionForceRequestBindings[digest],
           let existing = current.executionForceChallenges[challengeID] {
            guard existing.requestID == request.requestID,
                  existing.executionID == request.fence.executionID,
                  existing.authority == request.fence.authority,
                  existing.expectedSupervisorSequence == request.fence.expectedSupervisorSequence,
                  existing.actorID == request.actorID,
                  existing.sessionID == request.sessionID,
                  existing.audit == request.audit else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            challenge = existing
        } else {
            challenge = try .init(
                challengeID: .init(rawValue: RunBrokerExecutionForceEventIDs.challenge(
                    idempotencyKey: idempotencyKey
                )),
                requestDigest: digest,
                requestID: request.requestID,
                executionID: execution.manifest.executionID,
                authority: execution.authority,
                expectedSupervisorSequence: request.fence.expectedSupervisorSequence,
                actorID: request.actorID,
                sessionID: request.sessionID,
                audit: request.audit,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(5 * 60)
            )
            _ = try ledger.recordExecutionForceChallenge(
                challenge,
                eventID: .init(rawValue: challenge.challengeID.rawValue),
                occurredAt: now
            )
        }
        return .init(
            fence: request.fence,
            acceptedSupervisorSequence: try lastSupervisorSequence(
                executionID: request.fence.executionID
            ),
            cancellationIntent: nil,
            challenge: challenge,
            acceptedEffectID: nil
        )
    }

    private func confirmImmediateCancellation(
        _ confirmation: RunBrokerApplicationImmediateCancellationConfirmation,
        now: Date
    ) throws -> RunBrokerApplicationExecutionControlStatus {
        let projection: RunLedgerProjection
        do {
            projection = try ledger.projection()
        } catch is RunLedgerError {
            // Execution-force history is reduced at this public service
            // boundary. A stale or inconsistent historical fence must fail
            // closed as a stable typed rejection rather than exposing ledger
            // implementation details to an IPC caller.
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        guard let challenge = projection.executionForceChallenges[confirmation.challengeID],
              challenge.requestDigest == confirmation.requestDigest,
              challenge.executionID == confirmation.fence.executionID,
              challenge.authority == confirmation.fence.authority,
              challenge.expectedSupervisorSequence == confirmation.fence.expectedSupervisorSequence,
              challenge.actorID == confirmation.actorID,
              challenge.sessionID == confirmation.sessionID,
              confirmation.confirmedAt >= challenge.issuedAt,
              confirmation.confirmedAt <= challenge.expiresAt,
              confirmation.confirmedAt <= now else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        if let consumption = projection.executionForceConsumptions[confirmation.challengeID] {
            guard consumption.challenge == challenge,
                  consumption.effectID == confirmation.effectID,
                  consumption.confirmedAt == confirmation.confirmedAt,
                  let execution = projection.executions[confirmation.fence.executionID],
                  execution.authority == confirmation.fence.authority else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
        } else {
            // A new destructive confirmation must match the exact current
            // supervisor fence. An exact durable replay may observe a later
            // acceptance sequence and is instead fenced by its immutable
            // challenge-consumption record above.
            _ = try exactExecution(confirmation.fence)
        }
        _ = try ledger.consumeExecutionForceChallenge(
            challengeID: confirmation.challengeID,
            requestDigest: confirmation.requestDigest,
            effectID: confirmation.effectID,
            actorID: confirmation.actorID,
            sessionID: confirmation.sessionID,
            confirmedAt: confirmation.confirmedAt,
            eventID: .init(rawValue: RunBrokerExecutionForceEventIDs.consumption(
                effectID: confirmation.effectID
            ))
        )
        try orchestrator.requestImmediateTermination(
            .init(executionID: confirmation.fence.executionID, intent: .immediate),
            requestedAt: confirmation.confirmedAt,
            auditID: RunBrokerExecutionForceEventIDs.audit(effectID: confirmation.effectID)
        )
        return .init(
            fence: confirmation.fence,
            acceptedSupervisorSequence: try lastSupervisorSequence(
                executionID: confirmation.fence.executionID
            ),
            cancellationIntent: .immediate,
            challenge: challenge,
            acceptedEffectID: confirmation.effectID
        )
    }

    private static func canonicalMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(Int64(
            (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        )) / 1_000)
    }

    private func exactExecution(
        _ fence: RunBrokerApplicationExecutionFence
    ) throws -> RunLedgerExecutionProjection {
        guard let execution = try ledger.projection().executions[fence.executionID],
              execution.authority == fence.authority,
              try lastSupervisorSequence(executionID: fence.executionID)
                == fence.expectedSupervisorSequence else {
            throw RunBrokerApplicationEndpointError.executionNotFound
        }
        return execution
    }

    private func lastSupervisorSequence(executionID: RunBrokerExecutionID) throws -> UInt64 {
        var cursor: Int64 = 0
        var last: UInt64 = 0
        while true {
            let events = try ledger.events(after: cursor, limit: 1_000)
            guard !events.isEmpty else { return last }
            for stored in events {
                cursor = stored.sequence
                guard case .supervisorObservationRecorded(let observation) = stored.envelope.event,
                      observation.executionID == executionID else { continue }
                last = max(last, observation.supervisorSequence)
            }
        }
    }

    private func handleExternalOperation(
        _ command: RunBrokerApplicationExternalOperationCommand,
        idempotencyKey: UUID,
        now: Date
    ) throws -> ExternalOperationControlAssessment {
        let request: RunBrokerApplicationExternalOperationRequest
        let isControl: Bool
        switch command {
        case .observe(let value): request = value; isControl = false
        case .control(let value): request = value; isControl = true
        }
        guard let execution = try ledger.projection().executions[request.target.executionID],
              execution.authority == request.target.authority else {
            throw RunBrokerApplicationEndpointError.executionNotFound
        }

        let assessment: ExternalOperationControlAssessment
        if request.binding.backendIdentity.kind == .localRunSupervisor {
            let authenticator = RunBrokerSupervisorProvenanceAuthenticator(
                vault: vault,
                orchestrator: orchestrator,
                expectedManifestSHA256: try RuntimeSwitchDigests.manifest(execution.manifest),
                expectedCapabilities: [.observe, .immediateTermination]
            )
            do {
                assessment = try RunBrokerVerifiedExternalOperationControl.assess(
                    target: request.target,
                    binding: request.binding,
                    cancellationIntent: request.cancellationIntent,
                    authenticator: authenticator
                )
            } catch RunBrokerServiceError.supervisorUnavailable {
                // A vault record without an authenticated live handle or
                // capability-authenticated offline spool is only a descriptor.
                // Preserve the policy's typed unverified/blocked result.
                assessment = ExternalOperationControlPolicy.assess(
                    target: request.target,
                    binding: request.binding,
                    cancellationIntent: request.cancellationIntent
                )
            }
        } else {
            assessment = ExternalOperationControlPolicy.assess(
                target: request.target,
                binding: request.binding,
                cancellationIntent: request.cancellationIntent
            )
        }

        if !isControl {
            return assessment
        }

        guard assessment.cancellation.kind == .allowed else {
            // Monitoring-only and blocked are truth-bearing results, not
            // destructive effects. Return the exact policy explanation.
            return assessment
        }
        guard request.cancellationIntent == .immediate,
              assessment.cancellation.auditRequirement == .immediateTermination,
              supportsImmediateTermination else {
            // Graceful control is not wired or advertised in this release.
            throw RunBrokerApplicationEndpointError.externalOperationBlocked
        }
        try orchestrator.requestImmediateTermination(
            .init(executionID: request.target.executionID, intent: .immediate),
            requestedAt: now,
            auditID: idempotencyKey
        )
        return assessment
    }
}

struct RunBrokerSupervisorProvenanceAuthenticator:
    RunBrokerExternalOperationProvenanceAuthenticating
{
    let vault: any RunBrokerCapabilityVaulting
    let orchestrator: RunBrokerOrchestrator
    let expectedManifestSHA256: ExecutionLaunchArgumentsSHA256
    let expectedCapabilities: ExternalOperationControlCapabilities

    func authenticate(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) throws {
        guard binding.declaredCapabilities == expectedCapabilities,
              let claimed = binding.backendIdentity.supervisorIdentity,
              claimed.executionID == target.executionID,
              claimed.authority == target.authority,
              let record = try vault.load(executionID: target.executionID),
              record.identity.installationID == claimed.installationID,
              record.identity.storeID == claimed.storeID,
              record.identity.executionID == claimed.executionID,
              record.identity.authority == claimed.authority,
              record.manifestSHA256 == expectedManifestSHA256 else {
            throw RunBrokerExternalOperationVerificationError.descriptorMismatch
        }
        try orchestrator.authenticateSupervisorProvenance(
            identity: .init(
                installationID: claimed.installationID,
                storeID: claimed.storeID,
                executionID: claimed.executionID,
                authority: claimed.authority
            ),
            expectedManifestSHA256: expectedManifestSHA256
        )
    }
}

/// Domain-separated durable identities for one immediate-control effect.
/// Challenge issuance, confirmation consumption, and cancellation audit are
/// independent journal facts; deriving separate IDs prevents one fact from
/// being mistaken for an exact replay of another while retaining deterministic
/// recovery from the public effect ID.
enum RunBrokerExecutionForceEventIDs {
    static func challenge(idempotencyKey: UUID) -> UUID {
        derive(idempotencyKey, domain: "challenge")
    }

    static func consumption(effectID: RuntimeSwitchEffectID) -> UUID {
        derive(effectID.rawValue, domain: "consumption")
    }

    static func audit(effectID: RuntimeSwitchEffectID) -> UUID {
        derive(effectID.rawValue, domain: "cancellation-audit")
    }

    private static func derive(_ seed: UUID, domain: String) -> UUID {
        var data = Data("astra.execution-force.v2\u{0}\(domain)\u{0}".utf8)
        withUnsafeBytes(of: seed.uuid) { data.append(contentsOf: $0) }
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
