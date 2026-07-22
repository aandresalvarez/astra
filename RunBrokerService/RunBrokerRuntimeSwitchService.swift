import ASTRACore
import ASTRARunLedger
import CryptoKit
import Foundation
import RunBrokerClient
import RunBrokerPolicy

struct RunBrokerCheckpointEvidence: Equatable, Sendable {
    public let checkpointID: RuntimeSwitchCheckpointID
    public let generation: UInt64
    public let ledgerSequence: UInt64
    public let effectWatermark: UInt64
    public let toolOperationWatermark: UInt64
    public let inFlightEffectCount: UInt
    public let inFlightToolOperationCount: UInt
    public let providerContinuation: RuntimeSwitchProtocolIdentity
    public let supervisor: RuntimeSwitchSupervisorFence
}

struct RunBrokerControlAcceptanceEvidence: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let ledgerSequence: UInt64
}

struct RunBrokerTerminalEvidence: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let observedState: ExecutionObservedState
    public let ledgerSequence: UInt64
}

struct RunBrokerReplacementAcceptanceEvidence: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let ledgerSequence: UInt64
}

struct RunBrokerReplacementRunningEvidence: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let ledgerSequence: UInt64
}

/// Raw evidence/effect seam owned by the broker process. It exposes no secret
/// or verifier-minted attestation to the app/client target.
/// Internal broker-process seam. It is intentionally absent from public
/// package API so an app/client cannot inject a capability-claiming backend.
protocol RunBrokerRuntimeSwitchBackend: Sendable {
    var supportsGracefulHandoff: Bool { get }
    var supportsImmediateTermination: Bool { get }
    func safeCheckpoint(for record: RuntimeSwitchRecord) throws -> RunBrokerCheckpointEvidence?
    func handoffIf(_ directive: RuntimeSwitchControlDirective) throws
    func controlAcceptance(for record: RuntimeSwitchRecord) throws -> RunBrokerControlAcceptanceEvidence?
    func terminalEvidence(for record: RuntimeSwitchRecord) throws -> RunBrokerTerminalEvidence?
    func startReservedIf(
        reservation: RuntimeSwitchTargetReservation,
        manifestDigest: ExecutionLaunchArgumentsSHA256,
        effectID: RuntimeSwitchEffectID,
        directive: RuntimeSwitchReplacementDirective
    ) throws -> RunBrokerReplacementAcceptanceEvidence?
    func replacementRunning(for record: RuntimeSwitchRecord) throws -> RunBrokerReplacementRunningEvidence?
}

struct UnavailableRunBrokerRuntimeSwitchBackend: RunBrokerRuntimeSwitchBackend {
    init() {}
    let supportsGracefulHandoff = false
    let supportsImmediateTermination = false
    func safeCheckpoint(for: RuntimeSwitchRecord) throws -> RunBrokerCheckpointEvidence? { nil }
    func handoffIf(_: RuntimeSwitchControlDirective) throws {
        throw RunBrokerApplicationEndpointError.externalOperationBlocked
    }
    func controlAcceptance(for: RuntimeSwitchRecord) throws -> RunBrokerControlAcceptanceEvidence? { nil }
    func terminalEvidence(for: RuntimeSwitchRecord) throws -> RunBrokerTerminalEvidence? { nil }
    func startReservedIf(
        reservation: RuntimeSwitchTargetReservation,
        manifestDigest: ExecutionLaunchArgumentsSHA256,
        effectID: RuntimeSwitchEffectID,
        directive: RuntimeSwitchReplacementDirective
    ) throws -> RunBrokerReplacementAcceptanceEvidence? {
        throw RunBrokerApplicationEndpointError.externalOperationBlocked
    }
    func replacementRunning(for: RuntimeSwitchRecord) throws -> RunBrokerReplacementRunningEvidence? { nil }
}

enum RunBrokerRuntimeSwitchReconciliationDisposition: Equatable, Sendable {
    case idle
    case pending
    case awaitingConfirmation
    case completed
    case inDoubt
}

final class RunBrokerRuntimeSwitchService: @unchecked Sendable {
    private let ledger: RunLedger
    private let vault: any RunBrokerCapabilityVaulting
    private let orchestrator: RunBrokerOrchestrator
    private let backend: any RunBrokerRuntimeSwitchBackend
    private let lock = NSRecursiveLock()
    private var reconciliationSignal: (@Sendable () -> Void)?

    // Graceful control is deliberately unavailable until the production
    // supervisor protocol authenticates a graceful-handoff capability.
    var supportsGracefulHandoff: Bool { false }
    var supportsImmediateTermination: Bool { backend.supportsImmediateTermination }

    init(
        ledger: RunLedger,
        vault: any RunBrokerCapabilityVaulting,
        orchestrator: RunBrokerOrchestrator,
        backend: any RunBrokerRuntimeSwitchBackend = UnavailableRunBrokerRuntimeSwitchBackend()
    ) {
        self.ledger = ledger
        self.vault = vault
        self.orchestrator = orchestrator
        self.backend = backend
    }

    func submit(
        _ submission: RunBrokerApplicationRuntimeSwitchSubmission,
        now: Date
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        let status = try lock.withLock {
            try submitLocked(submission, now: now)
        }
        signalReconciliation()
        return status
    }

    private func submitLocked(
        _ submission: RunBrokerApplicationRuntimeSwitchSubmission,
        now: Date
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        try submission.validate(now: now)
        let request = try materializeRequest(submission)
        let requestDigest = try RuntimeSwitchDigests.request(request)
        let mutationTime = submission.requestedAt
        let existing = try ledger.projection().runtimeSwitchRequestBindings[submission.requestID]
        if let existing {
            guard existing.request == request,
                  existing.requestDigest == requestDigest else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            // A committed request is historical fact. Exact response-loss
            // retries must remain observable even if the live backend has
            // since been disabled, replaced, or lost a capability.
            return try statusLocked(
                requestID: submission.requestID,
                requestDigest: requestDigest
            )
        }
        guard mutationTime <= now.addingTimeInterval(5 * 60),
              now <= mutationTime.addingTimeInterval(5 * 60) else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        switch request.intent.mode {
        case .graceful where !supportsGracefulHandoff,
             .immediate where !backend.supportsImmediateTermination:
            throw RunBrokerApplicationEndpointError.externalOperationBlocked
        default: break
        }
        let reservationID = RuntimeSwitchEvidenceID(rawValue: deterministicID(
            request.intent.requestID.rawValue,
            domain: "target-reservation"
        ))
        let challenge: RuntimeForceSwitchChallenge?
        switch request {
        case .gracefulHandoff:
            challenge = nil
        case .forceTermination:
            challenge = try .init(
                challengeID: .init(rawValue: deterministicID(
                    request.intent.requestID.rawValue,
                    domain: "force-challenge"
                )),
                requestID: request.intent.requestID,
                requestDigest: requestDigest,
                actorID: try require(submission.actorID),
                sessionID: try require(submission.sessionID),
                issuedAt: mutationTime,
                expiresAt: mutationTime.addingTimeInterval(5 * 60)
            )
        }
        do {
            _ = try ledger.admitRuntimeSwitch(
                request: request,
                requestDigest: requestDigest,
                reservationID: reservationID,
                forceChallenge: challenge,
                eventID: .init(rawValue: deterministicID(
                    request.intent.requestID.rawValue,
                    domain: "admission"
                )),
                occurredAt: mutationTime
            )
        } catch is RunLedgerError {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        return try statusLocked(
            requestID: request.intent.requestID,
            requestDigest: requestDigest
        )
    }

    private func materializeRequest(
        _ submission: RunBrokerApplicationRuntimeSwitchSubmission
    ) throws -> ActiveRuntimeSwitchRequest {
        let draft = submission.targetDraft
        let authority = try RunBrokerAuthorityDerivation.runtimeSwitchTarget(
            installationID: ledger.identity.installationID,
            storeID: ledger.identity.storeID,
            requestID: submission.requestID,
            executionID: draft.executionID,
            taskID: draft.taskID,
            configuration: draft.configuration,
            declaredEffects: draft.declaredEffects,
            supervisionPolicy: draft.supervisionPolicy,
            createdAt: draft.createdAt
        )
        let manifest = ExecutionLaunchManifest(
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
        let target = try RuntimeSwitchResolvedTarget(
            manifest: manifest,
            manifestSHA256: RuntimeSwitchDigests.manifest(manifest)
        )
        let intent = try RuntimeSwitchIntent(
            requestID: submission.requestID,
            mode: submission.mode,
            expectedSource: submission.expectedSource,
            target: target,
            requestedAt: submission.requestedAt
        )
        switch submission.mode {
        case .graceful:
            return try .defaultHandoff(intent: intent)
        case .immediate:
            guard let audit = submission.forceAudit else {
                throw RunBrokerApplicationContractError.invalidRuntimeSwitch
            }
            return .forceTermination(try .init(intent: intent, audit: audit))
        }
    }

    func confirmImmediate(
        _ response: RunBrokerApplicationForceConfirmation,
        now: Date
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        // The confirmation may durably commit the transition out of
        // confirmationRequired and then throw during synchronous
        // reconciliation; a quiesced worker would otherwise never retry the
        // pending switch. Signaling on a pure-validation failure is a
        // harmless spurious wake.
        defer { signalReconciliation() }
        return try lock.withLock {
            try confirmImmediateLocked(response, now: now)
        }
    }

    private func confirmImmediateLocked(
        _ response: RunBrokerApplicationForceConfirmation,
        now: Date
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        let projection = try ledger.projection()
        let current = projection.runtimeSwitchPolicyState
        guard let record = current.record,
              record.request.intent.requestID == response.requestID,
              record.requestDigest == response.requestDigest,
              let challenge = record.forceChallenge,
              challenge.challengeID == response.challengeID,
              case .forceTermination(let request) = record.request else {
            // A confirmation whose response was lost after the switch
            // reconciled through completion finds the record already
            // archived. The effect was durably accepted, so the exact retry
            // is answered with the archived status instead of a rejection.
            if let archived = projection.runtimeSwitchArchivedRecords[response.requestID],
               Self.isExactArchivedConfirmation(response, archived: archived) {
                return RunBrokerRuntimeSwitchProjection.archivedStatus(archived)
            }
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        let confirmation = try VerifiedRuntimeForceConfirmation(
            confirmationID: .init(rawValue: deterministicID(response.effectID.rawValue, domain: "confirmation")),
            challenge: challenge,
            request: request,
            requestDigest: response.requestDigest,
            actorID: response.actorID,
            sessionID: response.sessionID,
            confirmedAt: response.confirmedAt,
            serverNow: now,
            effectID: response.effectID
        )
        let capability = try verifiedCapability(
            record: record,
            intent: .immediate,
            capabilityID: deterministicID(response.effectID.rawValue, domain: "capability")
        )
        let reduction = RuntimeSwitchPolicy.confirmImmediate(
            current,
            confirmation: confirmation,
            capability: capability
        )
        guard reduction.blockedReason == nil else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        if reduction.state != current {
            _ = try ledger.transitionRuntimeSwitchPolicy(
                expected: current,
                next: reduction.state,
                effectID: response.effectID,
                eventID: .init(rawValue: response.effectID.rawValue),
                occurredAt: now
            )
        }
        return try reconcile(now: now)
    }

    /// Lost-response recovery is safe only for the exact destructive command
    /// already recorded in the archived switch. Request/challenge correlation
    /// alone is insufficient because actor, session, effect identity, and the
    /// confirmed-at instant are independent authorization fences: the
    /// recorded timestamp is authenticated confirmation evidence, so a retry
    /// carrying any other instant is a different command, not a replay.
    static func isExactArchivedConfirmation(
        _ response: RunBrokerApplicationForceConfirmation,
        archived: RuntimeSwitchRecord
    ) -> Bool {
        guard archived.requestDigest == response.requestDigest,
              let challenge = archived.forceChallenge,
              let controlEffect = archived.controlEffect else {
            return false
        }
        return isExactArchivedConfirmation(
            response,
            challenge: challenge,
            recordedEffectID: controlEffect.effectID,
            recordedConfirmationID: controlEffect.confirmationID,
            recordedConfirmedAt: controlEffect.confirmedAt
        )
    }

    static func isExactArchivedConfirmation(
        _ response: RunBrokerApplicationForceConfirmation,
        challenge: RuntimeForceSwitchChallenge,
        recordedEffectID: RuntimeSwitchEffectID,
        recordedConfirmationID: RuntimeSwitchEvidenceID?,
        recordedConfirmedAt: Date?
    ) -> Bool {
        challenge.challengeID == response.challengeID
            && challenge.requestID == response.requestID
            && challenge.requestDigest == response.requestDigest
            && challenge.actorID == response.actorID
            && challenge.sessionID == response.sessionID
            && recordedEffectID == response.effectID
            && recordedConfirmationID == confirmationID(for: response.effectID)
            && recordedConfirmedAt == response.confirmedAt
    }

    static func confirmationID(for effectID: RuntimeSwitchEffectID) -> RuntimeSwitchEvidenceID {
        .init(rawValue: runtimeSwitchDeterministicID(effectID.rawValue, domain: "confirmation"))
    }

    func status(
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        now: Date
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        try lock.withLock {
            _ = now
            return try statusLocked(requestID: requestID, requestDigest: requestDigest)
        }
    }

    private func statusLocked(
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        let projection = try ledger.projection()
        if projection.runtimeSwitchPolicyState.record?.request.intent.requestID == requestID {
            let status = try RunBrokerRuntimeSwitchProjection.status(
                projection.runtimeSwitchPolicyState
            )
            guard status.requestDigest == requestDigest else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            return status
        }
        guard let archived = projection.runtimeSwitchArchivedRecords[requestID],
              archived.requestDigest == requestDigest else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        return RunBrokerRuntimeSwitchProjection.archivedStatus(archived)
    }

    func installReconciliationSignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { reconciliationSignal = signal }
    }

    func removeReconciliationSignal() {
        lock.withLock { reconciliationSignal = nil }
    }

    func reconcilePending(now: Date) throws -> RunBrokerRuntimeSwitchReconciliationDisposition {
        try lock.withLock {
            let state = try ledger.projection().runtimeSwitchPolicyState
            guard state.record != nil else { return .idle }
            _ = try reconcile(now: now)
            guard let progress = try ledger.projection().runtimeSwitchPolicyState.record?.progress else {
                return .idle
            }
            switch progress {
            case .confirmationRequired:
                return .awaitingConfirmation
            case .completed:
                return .completed
            case .inDoubt:
                return .inDoubt
            case .waitingForCheckpoint, .controlDispatchPending, .awaitingSourceTerminal,
                 .replacementDispatchPending, .awaitingReplacementRunning:
                return .pending
            }
        }
    }

    private func reconcile(now: Date) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        let current = try ledger.projection().runtimeSwitchPolicyState
        guard let record = current.record else {
            return try RunBrokerRuntimeSwitchProjection.status(current)
        }
        switch record.progress {
        case .waitingForCheckpoint:
            guard let raw = try backend.safeCheckpoint(for: record) else {
                return try RunBrokerRuntimeSwitchProjection.status(current)
            }
            let effectID = RuntimeSwitchEffectID(rawValue: deterministicID(
                record.request.intent.requestID.rawValue,
                domain: "control-effect"
            ))
            let attestation = try VerifiedRuntimeSwitchCheckpointAttestation(
                request: record.request,
                requestDigest: record.requestDigest,
                effectID: effectID,
                checkpointID: raw.checkpointID,
                checkpointGeneration: raw.generation,
                ledgerSequence: raw.ledgerSequence,
                effectWatermark: raw.effectWatermark,
                toolOperationWatermark: raw.toolOperationWatermark,
                inFlightEffectCount: raw.inFlightEffectCount,
                inFlightToolOperationCount: raw.inFlightToolOperationCount,
                providerContinuation: raw.providerContinuation,
                supervisor: raw.supervisor
            )
            let reduction = RuntimeSwitchPolicy.observeSafeCheckpoint(current, attestation: attestation)
            try commit(reduction, expected: current, effectID: effectID, now: now, domain: "checkpoint")
            return try reconcile(now: now)

        case .confirmationRequired:
            return try RunBrokerRuntimeSwitchProjection.status(current)

        case .controlDispatchPending:
            guard let effect = record.controlEffect else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            let capability = try verifiedCapability(
                record: record,
                intent: effect.cancellationIntent,
                capabilityID: effect.capabilityID?.rawValue
                    ?? deterministicID(effect.effectID.rawValue, domain: "graceful-capability")
            )
            let execution = try sourceExecution(record)
            let snapshot = VerifiedRuntimeSwitchDispatchSnapshot(
                effectID: effect.effectID,
                requestDigest: record.requestDigest,
                source: record.request.intent.expectedSource,
                lifecycle: Self.lifecycle(execution.control),
                observedCancellation: execution.control.observedCancellation,
                checkpointFence: effect.checkpointFence
            )
            let decision = RuntimeSwitchPolicy.prepareControlDispatch(
                current,
                effectID: effect.effectID,
                snapshot: snapshot,
                capability: capability
            )
            guard let directive = decision.directive else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            do {
                try backend.handoffIf(directive)
            } catch {
                return try markInDoubt(
                    current,
                    via: RuntimeSwitchPolicy.markSourceInDoubt,
                    now: now,
                    domain: "control-dispatch-ambiguous"
                )
            }
            guard let raw = try backend.controlAcceptance(for: record) else {
                return try RunBrokerRuntimeSwitchProjection.status(current)
            }
            let acceptance = VerifiedRuntimeSwitchControlAcceptance(
                evidenceID: raw.evidenceID,
                effectID: effect.effectID,
                source: effect.source,
                ledgerSequence: raw.ledgerSequence
            )
            let reduction = RuntimeSwitchPolicy.acknowledgeControl(current, acceptance: acceptance)
            try commit(reduction, expected: current, effectID: nil, now: now, domain: "control-accepted")
            return try reconcile(now: now)

        case .awaitingSourceTerminal:
            guard let raw = try backend.terminalEvidence(for: record) else {
                return try RunBrokerRuntimeSwitchProjection.status(current)
            }
            let replacementEffectID = RuntimeSwitchEffectID(rawValue: deterministicID(
                record.request.intent.requestID.rawValue,
                domain: "replacement-effect"
            ))
            let attestation = try VerifiedRuntimeSwitchTerminalAttestation(
                evidenceID: raw.evidenceID,
                source: record.request.intent.expectedSource,
                observedState: raw.observedState,
                ledgerSequence: raw.ledgerSequence,
                replacementEffectID: replacementEffectID
            )
            let reduction = RuntimeSwitchPolicy.observeSourceTerminal(current, attestation: attestation)
            try commit(reduction, expected: current, effectID: replacementEffectID, now: now, domain: "terminal")
            return try reconcile(now: now)

        case .replacementDispatchPending:
            guard let effect = record.replacementEffect else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            let snapshot = VerifiedRuntimeSwitchReplacementDispatchSnapshot(
                effectID: effect.effectID,
                sourceTerminal: effect.sourceTerminal,
                targetReservation: record.targetReservation,
                targetManifestSHA256: effect.target.manifestSHA256
            )
            let decision = RuntimeSwitchPolicy.prepareReplacementDispatch(
                current,
                effectID: effect.effectID,
                snapshot: snapshot
            )
            guard let directive = decision.directive else {
                throw RunBrokerApplicationEndpointError.requestRejected
            }
            try ledger.validateReservedStartIf(
                reservation: record.targetReservation,
                manifestDigest: effect.target.manifestSHA256,
                effectID: effect.effectID
            )
            let raw: RunBrokerReplacementAcceptanceEvidence?
            do {
                raw = try backend.startReservedIf(
                    reservation: record.targetReservation,
                    manifestDigest: effect.target.manifestSHA256,
                    effectID: effect.effectID,
                    directive: directive
                )
            } catch {
                return try markInDoubt(
                    current,
                    via: RuntimeSwitchPolicy.markReplacementDispatchInDoubt,
                    now: now,
                    domain: "replacement-dispatch-ambiguous"
                )
            }
            guard let raw else { return try RunBrokerRuntimeSwitchProjection.status(current) }
            let acceptance = VerifiedRuntimeSwitchReplacementAcceptance(
                evidenceID: raw.evidenceID,
                effectID: effect.effectID,
                targetReservationID: record.targetReservation.reservationID,
                targetExecutionID: effect.target.manifest.executionID,
                targetManifestSHA256: effect.target.manifestSHA256,
                ledgerSequence: raw.ledgerSequence
            )
            let reduction = RuntimeSwitchPolicy.acknowledgeReplacement(current, acceptance: acceptance)
            try commit(reduction, expected: current, effectID: nil, now: now, domain: "replacement-accepted")
            return try reconcile(now: now)

        case .awaitingReplacementRunning:
            guard let raw = try backend.replacementRunning(for: record),
                  let effect = record.replacementEffect else {
                return try RunBrokerRuntimeSwitchProjection.status(current)
            }
            let attestation = VerifiedRuntimeSwitchReplacementRunningAttestation(
                evidenceID: raw.evidenceID,
                targetReservationID: record.targetReservation.reservationID,
                targetExecutionID: effect.target.manifest.executionID,
                targetManifestSHA256: effect.target.manifestSHA256,
                ledgerSequence: raw.ledgerSequence
            )
            let reduction = RuntimeSwitchPolicy.observeReplacementRunning(current, attestation: attestation)
            try commit(reduction, expected: current, effectID: nil, now: now, domain: "replacement-running")
            // Completion is an intermediate durable state, not a quiescent
            // worker disposition. Continue in the same wake so the active
            // policy slot is archived before the worker can stop retrying.
            return try reconcile(now: now)

        case .completed:
            let archiveEvidenceID = RuntimeSwitchEvidenceID(rawValue: deterministicID(
                record.request.intent.requestID.rawValue,
                domain: "completion-archive-evidence"
            ))
            _ = try ledger.archiveRuntimeSwitchCompletion(
                expected: current,
                archiveEvidenceID: archiveEvidenceID,
                eventID: .init(rawValue: deterministicID(
                    record.request.intent.requestID.rawValue,
                    domain: "completion-archive"
                )),
                occurredAt: now
            )
            return try RunBrokerRuntimeSwitchProjection.status(
                ledger.projection().runtimeSwitchPolicyState
            )

        case .inDoubt:
            return try RunBrokerRuntimeSwitchProjection.status(current)
        }
    }

    private func commit(
        _ reduction: RuntimeSwitchPolicyReduction,
        expected: RuntimeSwitchPolicyState,
        effectID: RuntimeSwitchEffectID?,
        now: Date,
        domain: String
    ) throws {
        guard reduction.blockedReason == nil else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        guard reduction.state != expected else { return }
        guard let seed = reduction.state.record?.request.intent.requestID.rawValue
                ?? expected.record?.request.intent.requestID.rawValue else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        _ = try ledger.transitionRuntimeSwitchPolicy(
            expected: expected,
            next: reduction.state,
            effectID: effectID,
            eventID: .init(rawValue: deterministicID(seed, domain: domain)),
            occurredAt: now
        )
    }

    private func markInDoubt(
        _ state: RuntimeSwitchPolicyState,
        via reducer: (RuntimeSwitchPolicyState, RuntimeSwitchSourceFence)
            -> RuntimeSwitchPolicyReduction,
        now: Date,
        domain: String
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        guard let source = state.record?.request.intent.expectedSource else {
            throw RunBrokerApplicationEndpointError.requestRejected
        }
        let reduction = reducer(state, source)
        try commit(reduction, expected: state, effectID: nil, now: now, domain: domain)
        return try RunBrokerRuntimeSwitchProjection.status(reduction.state)
    }

    private func sourceExecution(
        _ record: RuntimeSwitchRecord
    ) throws -> RunLedgerExecutionProjection {
        let source = record.request.intent.expectedSource
        guard source.installationID == ledger.identity.installationID,
              source.storeID == ledger.identity.storeID,
              let execution = try ledger.projection().executions[source.executionID],
              execution.authority == source.authority,
              execution.manifest.installationID == source.installationID,
              execution.manifest.storeID == source.storeID,
              execution.manifest.taskID == source.taskID,
              execution.manifest.configuration.configurationRevision
                == source.configurationRevision,
              try RuntimeSwitchDigests.manifest(execution.manifest)
                == source.manifestSHA256 else {
            throw RunBrokerApplicationEndpointError.executionNotFound
        }
        return execution
    }

    /// PR8 vault evidence is the sole cancellation capability source. Only
    /// this broker-service target can mint the package-scoped attestation.
    private func verifiedCapability(
        record: RuntimeSwitchRecord,
        intent: ExecutionCancellationIntent,
        capabilityID: UUID
    ) throws -> VerifiedRuntimeSwitchBackendCapability {
        let source = record.request.intent.expectedSource
        guard intent == .immediate,
              backend.supportsImmediateTermination,
              let capability = try vault.load(executionID: source.executionID),
              capability.identity.installationID == source.installationID,
              capability.identity.storeID == source.storeID,
              capability.identity.executionID == source.executionID,
              capability.identity.authority == source.authority,
              capability.manifestSHA256 == source.manifestSHA256 else {
            throw RunBrokerApplicationEndpointError.externalOperationBlocked
        }
        let supervisor = try ExternalOperationSupervisorIdentity(
            installationID: source.installationID,
            storeID: source.storeID,
            executionID: source.executionID,
            authority: source.authority
        )
        let identity = ExternalOperationBackendIdentity(supervisorIdentity: supervisor)
        let capabilities: ExternalOperationControlCapabilities = intent == .graceful
            ? [.observe, .gracefulCancellation]
            : [.observe, .immediateTermination]
        let target = ExternalOperationControlTarget(
            executionID: source.executionID,
            authority: source.authority,
            backendIdentity: identity
        )
        let binding = ExternalOperationControlBinding(
            executionID: source.executionID,
            authority: source.authority,
            backendIdentity: identity,
            declaredCapabilities: capabilities
        )
        let assessment = try RunBrokerVerifiedExternalOperationControl.assess(
            target: target,
            binding: binding,
            cancellationIntent: intent,
            authenticator: RunBrokerSupervisorProvenanceAuthenticator(
                vault: vault,
                orchestrator: orchestrator,
                expectedManifestSHA256: source.manifestSHA256,
                expectedCapabilities: capabilities
            )
        )
        guard assessment.cancellation.kind == .allowed,
              assessment.cancellation.auditRequirement
                == (intent == .immediate ? .immediateTermination : nil) else {
            throw RunBrokerApplicationEndpointError.externalOperationBlocked
        }
        return try .init(
            capabilityID: .init(rawValue: capabilityID),
            requestDigest: record.requestDigest,
            source: source,
            cancellationIntent: intent
        )
    }

    private static func lifecycle(_ state: ExecutionControlState) -> RuntimeSwitchExecutionLifecycle {
        if state.observedExecution.isAuthoritativelyTerminal { return .terminal }
        if state.observedExecution == .inDoubt { return .inDoubt }
        if state.desiredCancellation != .none { return .cancellationPending }
        switch state.observedExecution {
        case .registered: return .registered
        case .starting: return .starting
        case .running: return .running
        case .completed, .failed, .cancelled: return .terminal
        case .inDoubt: return .inDoubt
        }
    }

    private func deterministicID(_ seed: UUID, domain: String) -> UUID {
        runtimeSwitchDeterministicID(seed, domain: domain)
    }

    private func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw RunBrokerApplicationEndpointError.requestRejected }
        return value
    }

    private func signalReconciliation() {
        let signal = lock.withLock { reconciliationSignal }
        signal?()
    }
}

private func runtimeSwitchDeterministicID(_ seed: UUID, domain: String) -> UUID {
    var data = Data("astra.runtime-switch.v2\u{0}\(domain)\u{0}".utf8)
    withUnsafeBytes(of: seed.uuid) { data.append(contentsOf: $0) }
    let bytes = Array(SHA256.hash(data: data).prefix(16))
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
