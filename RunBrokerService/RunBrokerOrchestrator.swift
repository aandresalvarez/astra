import ASTRACore
import ASTRARunLedger
import CryptoKit
import Foundation
import RunSupervisorSupport

public final class RunBrokerOrchestrator: @unchecked Sendable {
    private struct JournalState {
        var observations: [UInt64: RunBrokerSupervisorObservation] = [:]
        var persistedOutputBytes: UInt64 = 0
        var sawReady = false
        var sawProviderStarted = false
        var sawCancellationConfirmed = false
        var terminal = false
        var terminalTailComplete = false

        var lastSequence: UInt64 { observations.keys.max() ?? 0 }
    }

    private let ledger: RunLedger
    private let vault: any RunBrokerCapabilityVaulting
    private let spawner: any RunBrokerSupervisorSpawning
    private let transport: any RunBrokerSupervisorTransporting
    private let installedBrokerExecutableURL: URL
    private let faultInjector: any RunBrokerStartFaultInjecting
    private let terminationAuthorizer: any RunBrokerImmediateTerminationAuthorizing
    private let logger: any RunBrokerServiceLogging
    private let lock = NSRecursiveLock()
    public let supportsAuthenticatedImmediateTermination: Bool

    public init(
        ledger: RunLedger,
        vault: any RunBrokerCapabilityVaulting,
        spawner: any RunBrokerSupervisorSpawning,
        transport: any RunBrokerSupervisorTransporting,
        installedBrokerExecutableURL: URL,
        faultInjector: any RunBrokerStartFaultInjecting = NoOpRunBrokerStartFaultInjector(),
        allowAuthenticatedImmediateTermination: Bool = false,
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        self.ledger = ledger
        self.vault = vault
        self.spawner = spawner
        self.transport = transport
        self.installedBrokerExecutableURL = installedBrokerExecutableURL
        self.faultInjector = faultInjector
        self.terminationAuthorizer = allowAuthenticatedImmediateTermination
            ? AllowExactRunBrokerImmediateTerminationAuthorizer()
            : DenyRunBrokerImmediateTerminationAuthorizer()
        self.supportsAuthenticatedImmediateTermination = allowAuthenticatedImmediateTermination
        self.logger = logger
    }

    init(
        ledger: RunLedger,
        vault: any RunBrokerCapabilityVaulting,
        spawner: any RunBrokerSupervisorSpawning,
        transport: any RunBrokerSupervisorTransporting,
        installedBrokerExecutableURL: URL,
        faultInjector: any RunBrokerStartFaultInjecting,
        terminationAuthorizer: any RunBrokerImmediateTerminationAuthorizing,
        logger: any RunBrokerServiceLogging
    ) {
        self.ledger = ledger
        self.vault = vault
        self.spawner = spawner
        self.transport = transport
        self.installedBrokerExecutableURL = installedBrokerExecutableURL
        self.faultInjector = faultInjector
        self.terminationAuthorizer = terminationAuthorizer
        self.supportsAuthenticatedImmediateTermination =
            terminationAuthorizer.allowsImmediateTermination
        self.logger = logger
    }

    /// Durable broker launch path. This API is intentionally not called by the
    /// app in PR7; PR9 will switch runtime authority explicitly after rollout
    /// gates pass. There is no local-process fallback.
    public func start(_ request: RunBrokerStartRequest) throws -> RunBrokerReconciliationOutcome {
        try lock.withLock {
            guard request.authorityMode == .durableBroker else {
                throw RunBrokerServiceError.localAuthorityForbidden
            }
            guard request.manifest.installationID == ledger.identity.installationID else {
                throw RunBrokerServiceError.installationIdentityMismatch
            }
            guard request.manifest.storeID == ledger.identity.storeID else {
                throw RunBrokerServiceError.storeIdentityMismatch
            }
            guard request.manifest.supervisionPolicy != nil else {
                throw RunBrokerServiceError.missingSupervisionPolicy
            }
            do {
                _ = try ledger.preflightExecutionAdmission(
                    manifest: request.manifest,
                    primaryOperationID: request.primaryOperationID,
                    admittedAt: request.manifest.createdAt,
                    idempotencyKey: request.admissionID
                )
            } catch RunLedgerError.eventIDReuse {
                throw RunBrokerServiceError.idempotencyKeyConflict
            }
            let identity = RunSupervisorIdentity(manifest: request.manifest)
            let digest = try RunSupervisorDigests.manifest(request.manifest)
            let existing = try vault.load(executionID: request.manifest.executionID)
            let capability: RunSupervisorCapability
            if let existing {
                guard existing.identity == identity, existing.manifestSHA256 == digest else {
                    throw RunBrokerServiceError.capabilityIdentityMismatch
                }
                capability = existing.capability
            } else {
                capability = try RunSupervisorCapability.random()
            }
            let payload = RunSupervisorBootstrapPayload(
                manifest: request.manifest,
                manifestSHA256: digest,
                expectedIdentity: identity,
                arguments: request.arguments,
                environment: request.environment,
                capability: capability
            )
            do {
                try RunSupervisorBootstrapValidator.validate(payload)
            } catch {
                throw RunBrokerServiceError.invalidManifest
            }
            let launchMaterialAuthenticator = try RunSupervisorDigests.launchAuthenticator(
                payload: payload,
                capability: capability
            )
            if let existing,
               existing.launchMaterialAuthenticator != launchMaterialAuthenticator {
                throw RunBrokerServiceError.launchMaterialConflict
            }
            try faultInjector.checkpoint(.afterValidation)

            let admission = try ledger.admitExecution(
                manifest: request.manifest,
                primaryOperationID: request.primaryOperationID,
                admittedAt: request.manifest.createdAt,
                idempotencyKey: request.admissionID
            )
            try faultInjector.checkpoint(.afterLedgerAdmission)

            // Admission is the durable authority boundary. Publishing a
            // capability first can strand irrevocable authority-shaped state
            // when a concurrent admission denial wins after preflight. A
            // crash after admission but before capability publication is safe:
            // no supervisor can exist yet, and the exact retry reconstructs
            // and synchronizes launch material before spawning once.
            if existing == nil {
                try vault.persistAndSynchronize(.init(
                    identity: identity,
                    manifestSHA256: digest,
                    capability: capability,
                    launchMaterialAuthenticator: launchMaterialAuthenticator
                ))
            }
            try faultInjector.checkpoint(.afterCapabilitySync)

            if admission.disposition == .exactReplay {
                do {
                    switch try transport.presence(identity: identity, capability: capability) {
                    case .authenticated:
                        // A running or offline exact supervisor already owns
                        // the execution. Reconcile durable evidence; never
                        // blindly respawn on an application retry.
                        return try reconcileLocked(
                            executionID: request.manifest.executionID,
                            startFaultsEnabled: false
                        )
                    case .absent:
                        // Absence of the execution directory is the only
                        // proof that a crash happened before spawn began.
                        break
                    }
                } catch {
                    // Existing but unauthenticated/ambiguous supervisor state
                    // is recovery truth, not permission to spawn a replacement.
                    return try reconcileLocked(
                        executionID: request.manifest.executionID,
                        startFaultsEnabled: false
                    )
                }
            }

            try spawner.spawn(
                payload: payload,
                installedBrokerExecutableURL: installedBrokerExecutableURL
            )
            logger.record(event: "run_broker.supervisor_spawned", fields: safeFields(identity))
            try faultInjector.checkpoint(.afterSupervisorSpawn)
            do {
                return try reconcileLocked(
                    executionID: request.manifest.executionID,
                    startFaultsEnabled: true
                )
            } catch let error where RunSupervisorTrustedRoot.isExecutionDirectoryAbsence(error) {
                // The production spawner returns as soon as the bootstrap
                // payload is handed to the child; the supervisor creates its
                // execution directory and authenticated spool asynchronously.
                // Absence of transport evidence inside this launch window is
                // not an application failure: admission, capability, and the
                // launch binding are already durable, so report the admitted
                // state and let broker-owned reconciliation observe the
                // supervisor by identity once it publishes evidence. This
                // path never generates a second launch.
                logger.record(
                    event: "run_broker.supervisor_launch_pending",
                    fields: safeFields(identity)
                )
                return .init(state: .admitted, lastSupervisorSequence: 0, replaySource: nil)
            }
        }
    }

    public func reconcile(
        executionID: RunBrokerExecutionID
    ) throws -> RunBrokerReconciliationOutcome {
        try lock.withLock {
            try resumeConsumedImmediateTermination(executionID: executionID)
            return try reconcileLocked(executionID: executionID, startFaultsEnabled: false)
        }
    }

    /// Challenge consumption is the durable authorization boundary. If the
    /// broker crashes after consuming the one-time confirmation but before
    /// appending its cancellation audit, the periodic execution reconciler
    /// must resume that exact effect without requiring the app to replay the
    /// confirmation. Authority transfer fences historical consumptions.
    private func resumeConsumedImmediateTermination(
        executionID: RunBrokerExecutionID
    ) throws {
        guard supportsAuthenticatedImmediateTermination else { return }
        let projection = try ledger.projection()
        guard let execution = projection.executions[executionID],
              !execution.control.observedExecution.isAuthoritativelyTerminal else {
            return
        }
        let consumption = projection.executionForceConsumptions.values
            .filter {
                $0.challenge.executionID == executionID
                    && $0.challenge.authority == execution.authority
            }
            .sorted {
                if $0.confirmedAt != $1.confirmedAt {
                    return $0.confirmedAt < $1.confirmedAt
                }
                return $0.effectID.rawValue.uuidString < $1.effectID.rawValue.uuidString
            }
            .first
        guard let consumption else { return }
        try requestImmediateTermination(
            .init(executionID: executionID, intent: .immediate),
            requestedAt: consumption.confirmedAt,
            auditID: RunBrokerExecutionForceEventIDs.audit(effectID: consumption.effectID)
        )
    }

    /// Proves that the exact execution-scoped supervisor handle is currently
    /// authenticated by live control or its capability-authenticated offline
    /// spool. A durable vault record alone is preparation state, not runtime
    /// provenance and cannot authorize observation or destructive control.
    func authenticateSupervisorProvenance(
        identity: RunSupervisorIdentity,
        expectedManifestSHA256: ExecutionLaunchArgumentsSHA256
    ) throws {
        try lock.withLock {
            guard let execution = try ledger.projection().executions[identity.executionID],
                  execution.manifest.installationID == identity.installationID,
                  execution.manifest.storeID == identity.storeID,
                  execution.authority == identity.authority,
                  try RunSupervisorDigests.manifest(execution.manifest)
                    == expectedManifestSHA256,
                  let capability = try vault.load(executionID: identity.executionID),
                  capability.identity == identity,
                  capability.manifestSHA256 == expectedManifestSHA256,
                  try transport.presence(
                    identity: identity,
                    capability: capability.capability
                  ) == .authenticated else {
                throw RunBrokerServiceError.supervisorUnavailable
            }
            let outcome = try reconcileLocked(
                executionID: identity.executionID,
                startFaultsEnabled: false
            )
            guard outcome.state != .inDoubt, outcome.replaySource != nil else {
                throw RunBrokerServiceError.supervisorUnavailable
            }
        }
    }

    /// The durable cancellation-intent append is the audit boundary. The
    /// supervisor effect is never issued first and PID-based termination is not
    /// available through this service.
    public func requestImmediateTermination(
        _ request: RunBrokerImmediateTerminationRequest,
        requestedAt: Date,
        auditID: UUID
    ) throws {
        try lock.withLock {
            guard request.intent == .immediate else {
                throw RunBrokerServiceError.immediateTerminationUnauthorized
            }
            guard let execution = try ledger.projection().executions[request.executionID] else {
                throw RunBrokerServiceError.supervisorIdentityMismatch
            }
            let identity = RunSupervisorIdentity(
                installationID: execution.manifest.installationID,
                storeID: execution.manifest.storeID,
                executionID: request.executionID,
                authority: execution.authority
            )
            let authorization = try terminationAuthorizer.authorize(
                request: request,
                expectedIdentity: identity
            )
            guard authorization.identity == identity else {
                throw RunBrokerServiceError.immediateTerminationUnauthorized
            }
            guard let capability = try vault.load(executionID: request.executionID),
                  capability.identity == identity else {
                throw RunBrokerServiceError.missingCapability
            }

            // The caller's wall-clock is not part of mutation identity. A
            // response-lost retry arrives at a later time but must still be an
            // exact replay of the same durable control intent.
            let replay = try preflightImmediateTerminationAudit(
                executionID: request.executionID,
                authority: identity.authority,
                auditID: auditID
            )
            if !replay {
                _ = try ledger.append(.init(
                    eventID: .init(rawValue: auditID),
                    // Recovery may resume long after confirmation while later
                    // supervisor observations have advanced durable execution
                    // time. Preserve the original authorization identity but
                    // never append a control transition behind ledger truth.
                    occurredAt: max(requestedAt, execution.updatedAt),
                    event: .executionControlTransitioned(
                        executionID: request.executionID,
                        authority: identity.authority,
                        transition: .requestCancellation(.immediate),
                        backendCapabilities: [.observe, .cancel]
                    )
                ))
            }
            logger.record(event: "run_broker.immediate_termination_audited", fields: safeFields(identity))

            if replay {
                let outcome = try reconcileLocked(
                    executionID: request.executionID,
                    startFaultsEnabled: false
                )
                guard outcome.state != .inDoubt else {
                    throw RunBrokerServiceError.supervisorUnavailable
                }
                // The supervisor durably spools cancellation_requested before
                // touching its owned process. Seeing that exact immediate
                // request (or terminal truth) proves the destructive command
                // was accepted; do not issue it twice after a lost response.
                if try hasAcceptedImmediateTermination(executionID: request.executionID) {
                    return
                }
            }
            try transport.requestImmediateTermination(
                identity: identity,
                capability: capability.capability
            )
            logger.record(event: "run_broker.immediate_termination_issued", fields: safeFields(identity))
        }
    }

    private func preflightImmediateTerminationAudit(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        auditID: UUID
    ) throws -> Bool {
        guard let existing = try ledger.event(eventID: .init(rawValue: auditID)) else {
            return false
        }
        guard case .executionControlTransitioned(
            let recordedExecutionID,
            let recordedAuthority,
            .requestCancellation(.immediate),
            let capabilities
        ) = existing.envelope.event,
              recordedExecutionID == executionID,
              recordedAuthority == authority,
              capabilities == [.observe, .cancel] else {
            throw RunBrokerServiceError.idempotencyKeyConflict
        }
        return true
    }

    private func hasAcceptedImmediateTermination(
        executionID: RunBrokerExecutionID
    ) throws -> Bool {
        let journal = try journalState(executionID: executionID)
        return journal.terminal || journal.observations.values.contains { observation in
            switch observation.kind {
            case .cancellationRequested:
                observation.cancellationIntent == .immediate
            case .terminationStarted, .cancellationConfirmed:
                true
            default:
                false
            }
        }
    }

    private func reconcileLocked(
        executionID: RunBrokerExecutionID,
        startFaultsEnabled: Bool
    ) throws -> RunBrokerReconciliationOutcome {
        guard let execution = try ledger.projection().executions[executionID] else {
            throw RunBrokerServiceError.supervisorIdentityMismatch
        }
        let wasAuthoritativelyTerminal = execution.control.observedExecution
            .isAuthoritativelyTerminal
        if wasAuthoritativelyTerminal,
           try journalState(executionID: executionID).terminalTailComplete {
            // providerExited/providerLaunchFailed is the supervisor's final
            // lifecycle record. Once that tail is durable, retired recovery
            // dependencies are no longer needed. cancellationConfirmed is
            // terminal control truth but is not the end of the spool: the
            // subsequent providerExited audit evidence still must be drained.
            return try terminalOutcome(executionID: executionID)
        }
        // Two distinct identities meet here. The supervisor process and its
        // vaulted capability are bound forever to the immutable LAUNCH
        // identity from the manifest; a journaled authority transfer never
        // re-bootstraps the child. Ledger appends, by contrast, must carry
        // the CURRENT authority from the projection or the fencing primitive
        // rejects them as stale. Conflating the two turned every legal
        // transfer into a permanent capability/identity mismatch.
        let launchIdentity = RunSupervisorIdentity(manifest: execution.manifest)
        let identity = RunSupervisorIdentity(
            installationID: execution.manifest.installationID,
            storeID: execution.manifest.storeID,
            executionID: executionID,
            authority: execution.authority
        )
        guard let capability = try vault.load(executionID: executionID) else {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            return try markInDoubt(identity: identity, reason: "missing_capability")
        }
        guard capability.identity == launchIdentity,
              capability.manifestSHA256 == (try RunSupervisorDigests.manifest(execution.manifest)) else {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            return try markInDoubt(identity: identity, reason: "capability_identity_mismatch")
        }
        guard let policy = execution.manifest.supervisionPolicy else {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            return try markInDoubt(identity: identity, reason: "missing_policy")
        }

        var state = try journalState(executionID: executionID)
        var lastSource: RunBrokerSupervisorReplaySource?
        var acknowledgedThisPass: UInt64 = 0
        var quotaTerminationNeedsRetry = state.observations.values.contains {
            $0.kind == .outputQuotaExceeded
        } && !state.observations.values.contains {
            [.cancellationRequested, .terminationStarted, .cancellationConfirmed, .providerExited]
                .contains($0.kind)
        }
        do {
            // A crash may commit an authenticated observation but not its
            // derived execution-control transition. Repair from canonical
            // journal truth before asking the supervisor for events after
            // the durable cursor.
            for observation in state.observations.values.sorted(by: {
                $0.supervisorSequence < $1.supervisorSequence
            }) {
                try ensureDerivedControl(
                    for: supervisorEvent(from: observation),
                    identity: identity,
                    state: &state
                )
            }
            while true {
                let batch = try transport.replay(
                    identity: launchIdentity,
                    capability: capability.capability,
                    after: state.lastSequence
                )
                guard batch.identity == launchIdentity else {
                    return try markInDoubt(identity: identity, reason: "supervisor_identity_mismatch")
                }
                guard batch.lastSequence >= state.lastSequence,
                      batch.events.allSatisfy({ $0.sequence <= batch.lastSequence }),
                      zip(batch.events, batch.events.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else {
                    return try markInDoubt(identity: identity, reason: "supervisor_replay_inconsistent")
                }
                lastSource = batch.source
                guard !batch.events.isEmpty else {
                    if batch.lastSequence > state.lastSequence {
                        throw RunBrokerServiceError.nonContiguousSupervisorSequence(
                            expected: state.lastSequence + 1,
                            found: batch.lastSequence
                        )
                    }
                    if state.lastSequence > acknowledgedThisPass {
                        try transport.acknowledge(
                            identity: launchIdentity,
                            capability: capability.capability,
                            source: batch.source,
                            through: state.lastSequence
                        )
                        acknowledgedThisPass = state.lastSequence
                    }
                    if quotaTerminationNeedsRetry, !state.terminal {
                        try issueOutputQuotaTermination(
                            identity: identity,
                            launchIdentity: launchIdentity,
                            capability: capability.capability
                        )
                        quotaTerminationNeedsRetry = false
                    }
                    break
                }
                for event in batch.events {
                    quotaTerminationNeedsRetry = try persist(
                        event,
                        identity: identity,
                        manifestCreatedAt: execution.manifest.createdAt,
                        policy: policy,
                        state: &state,
                        startFaultsEnabled: startFaultsEnabled
                    ) || quotaTerminationNeedsRetry
                }
                try transport.acknowledge(
                    identity: launchIdentity,
                    capability: capability.capability,
                    source: batch.source,
                    through: state.lastSequence
                )
                acknowledgedThisPass = state.lastSequence
                if quotaTerminationNeedsRetry, !state.terminal {
                    try issueOutputQuotaTermination(
                        identity: identity,
                        launchIdentity: launchIdentity,
                        capability: capability.capability
                    )
                    quotaTerminationNeedsRetry = false
                }
                if state.lastSequence >= batch.lastSequence { break }
            }
        } catch let error as RunBrokerServiceError {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            switch error {
            case .supervisorIdentityMismatch, .supervisorUnavailable,
                 .capabilityIdentityMismatch, .nonContiguousSupervisorSequence,
                 .supervisorEventConflict, .providerStartedBeforeReady:
                return try markInDoubt(identity: identity, reason: "authenticated_recovery_failed")
            default:
                throw error
            }
        } catch RunSupervisorError.authenticationFailed,
                RunSupervisorError.responseAuthenticationFailed,
                RunSupervisorError.invalidIdentity,
                RunSupervisorError.launchPayloadConflict {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            return try markInDoubt(identity: identity, reason: "authentication_failed")
        } catch RunLedgerError.eventIDReuse {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            // Deterministic observation/derived-control event IDs are bound
            // to exact recorded facts. A same-ID different-content collision
            // means supervisor evidence and journal truth diverge. That is
            // observable recovery state, not a programming error: mark the
            // execution in-doubt instead of letting reconcile throw the raw
            // ledger error forever without ever reaching a durable verdict.
            return try markInDoubt(identity: identity, reason: "durable_evidence_conflict")
        } catch {
            if wasAuthoritativelyTerminal {
                return try terminalOutcome(executionID: executionID)
            }
            throw error
        }

        if lastSource == .offlineAuthenticatedSpool, !state.terminal {
            // An offline spool can only be opened after the supervisor has
            // released ownership. Once that durable source is exhausted,
            // absence of terminal evidence is an incomplete lifecycle, not a
            // running execution. Persist the uncertainty instead of silently
            // projecting stale running/admitted state forever.
            return try markInDoubt(
                identity: identity,
                reason: "offline_spool_missing_terminal"
            )
        }

        let projected = try ledger.projection().executions[executionID]
        let terminal = projected?.control.observedExecution.isAuthoritativelyTerminal == true
        let running = projected?.control.observedExecution == .running
        return .init(
            state: terminal ? .terminal : (running ? .running : .admitted),
            lastSupervisorSequence: state.lastSequence,
            replaySource: lastSource
        )
    }

    private func terminalOutcome(
        executionID: RunBrokerExecutionID
    ) throws -> RunBrokerReconciliationOutcome {
        let journal = try journalState(executionID: executionID)
        return .init(
            state: .terminal,
            lastSupervisorSequence: journal.lastSequence,
            replaySource: nil
        )
    }

    private func issueOutputQuotaTermination(
        identity: RunSupervisorIdentity,
        launchIdentity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {
        try transport.requestImmediateTermination(
            identity: launchIdentity,
            capability: capability
        )
        logger.record(
            event: "run_broker.output_quota_termination_issued",
            fields: safeFields(identity)
        )
    }

    private func persist(
        _ event: RunSupervisorEvent,
        identity: RunSupervisorIdentity,
        manifestCreatedAt: Date,
        policy: ExecutionSupervisionPolicySnapshot,
        state: inout JournalState,
        startFaultsEnabled: Bool
    ) throws -> Bool {
        if let existing = state.observations[event.sequence] {
            let requested = observation(
                event,
                identity: identity,
                manifestCreatedAt: manifestCreatedAt
            )
            // The recording authority is broker-side metadata, not supervisor
            // evidence. Identical supervisor content journaled before an
            // authority transfer replays under the successor epoch and must
            // be recognized as the same recorded fact.
            guard supervisorContentMatches(recorded: existing, derived: requested),
                  isRecordedUnderCurrentOrEarlierAuthority(
                    existing.authority,
                    current: identity.authority
                  ) else {
                throw RunBrokerServiceError.supervisorEventConflict(sequence: event.sequence)
            }
            try ensureDerivedControl(for: event, identity: identity, state: &state)
            return false
        }
        let expected = state.lastSequence + 1
        guard event.sequence == expected else {
            throw RunBrokerServiceError.nonContiguousSupervisorSequence(
                expected: expected,
                found: event.sequence
            )
        }
        if event.kind == .providerStarted, !state.sawReady {
            throw RunBrokerServiceError.providerStartedBeforeReady
        }
        var durableEvent = event
        var requiresQuotaTermination = false
        if let output = event.payload.data {
            let outputBytes = UInt64(output.count)
            if outputBytes > policy.maximumOutputEventBytes
                || outputBytes > policy.maximumPersistedOutputBytes
                || state.persistedOutputBytes > policy.maximumPersistedOutputBytes - outputBytes {
                durableEvent = .init(
                    sequence: event.sequence,
                    id: event.id,
                    timestamp: event.timestamp,
                    kind: .outputQuotaExceeded,
                    payload: .init(quarantinedByteCount: outputBytes)
                )
                requiresQuotaTermination = true
            }
        }

        let durable = observation(
            durableEvent,
            identity: identity,
            manifestCreatedAt: manifestCreatedAt
        )
        _ = try ledger.append(.init(
            eventID: deterministicEventID(event.id, domain: "supervisor-observation"),
            occurredAt: durable.occurredAt,
            event: .supervisorObservationRecorded(durable)
        ))
        state.observations[event.sequence] = durable
        state.persistedOutputBytes += UInt64(durableEvent.payload.data?.count ?? 0)
        if durableEvent.kind == .supervisorReady {
            state.sawReady = true
            if startFaultsEnabled { try faultInjector.checkpoint(.afterReadyEvidence) }
        }
        if durableEvent.kind == .providerStarted {
            state.sawProviderStarted = true
            try faultInjector.checkpoint(.afterProviderStartedObservation)
            try appendControl(
                .executionStarted,
                identity: identity,
                event: durableEvent,
                domain: "execution-started"
            )
            if startFaultsEnabled { try faultInjector.checkpoint(.afterProviderStartedEvidence) }
        }
        if durableEvent.kind.isTerminalTruth {
            try faultInjector.checkpoint(.afterTerminalObservation)
        }
        if requiresQuotaTermination {
            try appendControl(
                .requestCancellation(.immediate),
                identity: identity,
                event: durableEvent,
                domain: "output-quota-cancellation"
            )
        }
        try ensureDerivedControl(for: durableEvent, identity: identity, state: &state)
        logger.record(
            event: "run_broker.supervisor_event_durable",
            fields: safeFields(identity).merging([
                "sequence": String(event.sequence),
                "kind": durableEvent.kind.rawValue,
            ]) { _, new in new }
        )
        return requiresQuotaTermination
    }

    private func ensureDerivedControl(
        for event: RunSupervisorEvent,
        identity: RunSupervisorIdentity,
        state: inout JournalState
    ) throws {
        switch event.kind {
        case .providerStarted:
            state.sawProviderStarted = true
            try appendControl(
                .executionStarted,
                identity: identity,
                event: event,
                domain: "execution-started"
            )
        case .providerLaunchFailed:
            try appendControl(
                .executionFailed,
                identity: identity,
                event: event,
                domain: "execution-launch-failed"
            )
            state.terminal = true
            state.terminalTailComplete = true
        case .providerExited:
            // Immediate cancellation records cancellationConfirmed before the
            // wrapper is reaped and providerExited is emitted. The exit is
            // still durable audit evidence, but cancellation is already the
            // authoritative terminal outcome and cannot be transitioned again.
            if !state.sawCancellationConfirmed {
                try appendControl(
                    event.payload.exitCode == 0 ? .executionCompleted : .executionFailed,
                    identity: identity,
                    event: event,
                    domain: "execution-exited"
                )
            }
            state.terminal = true
            state.terminalTailComplete = true
        case .cancellationConfirmed:
            try appendControl(
                .cancellationConfirmed,
                identity: identity,
                event: event,
                domain: "cancellation-confirmed"
            )
            state.sawCancellationConfirmed = true
            state.terminal = true
        case .terminationStarted:
            try appendControl(
                .terminationStarted,
                identity: identity,
                event: event,
                domain: "termination-started"
            )
        default:
            break
        }
    }

    private func appendControl(
        _ transition: RunLedgerExecutionControlEvent,
        identity: RunSupervisorIdentity,
        event: RunSupervisorEvent,
        domain: String
    ) throws {
        let eventID = deterministicEventID(event.id, domain: domain)
        // A derived control event is a fact derived exactly once from its
        // source observation, journaled under the authority that was current
        // at that moment. Replay re-derives under the projection's CURRENT
        // authority, so after a journaled authority transfer the same
        // deterministic ID would carry a different payload and the ledger's
        // event-ID fence would reject every subsequent reconcile. Recognize
        // the journaled fact by exact ID and provenance instead of
        // re-deriving it; only a genuinely different fact under this ID is a
        // conflict.
        if let existing = try ledger.event(eventID: eventID) {
            guard case .executionControlTransitioned(
                let recordedExecutionID,
                let recordedAuthority,
                let recordedTransition,
                let recordedCapabilities
            ) = existing.envelope.event,
                recordedExecutionID == identity.executionID,
                recordedTransition == transition,
                recordedCapabilities == [.observe, .cancel],
                isRecordedUnderCurrentOrEarlierAuthority(
                    recordedAuthority,
                    current: identity.authority
                ) else {
                throw RunLedgerError.eventIDReuse(eventID)
            }
            return
        }
        // The supervisor's clock is not the ledger's clock. The projector
        // enforces per-execution monotonicity, so anchor the fresh fact to
        // its observation time but never behind the durable execution state
        // (mirrors markInDoubt's clamp). Replays never recompute this value:
        // the exact-ID recognition above accepts the journaled event.
        let executionUpdatedAt = try ledger.projection()
            .executions[identity.executionID]?.updatedAt
        _ = try ledger.append(.init(
            eventID: eventID,
            occurredAt: max(event.timestamp, executionUpdatedAt ?? event.timestamp),
            event: .executionControlTransitioned(
                executionID: identity.executionID,
                authority: identity.authority,
                transition: transition,
                backendCapabilities: [.observe, .cancel]
            )
        ))
    }

    /// A fact recorded under an earlier fencing epoch stays true after a
    /// journaled authority transfer. Only a same-epoch different-identity or
    /// future-epoch recording conflicts with the current authority.
    private func isRecordedUnderCurrentOrEarlierAuthority(
        _ recorded: RunBrokerAuthority,
        current: RunBrokerAuthority
    ) -> Bool {
        recorded.epoch < current.epoch || recorded == current
    }

    /// Supervisor-evidence equality independent of broker-side recording
    /// metadata (the journaling authority).
    private func supervisorContentMatches(
        recorded: RunBrokerSupervisorObservation,
        derived: RunBrokerSupervisorObservation
    ) -> Bool {
        recorded.executionID == derived.executionID
            && recorded.supervisorSequence == derived.supervisorSequence
            && recorded.supervisorEventID == derived.supervisorEventID
            && recorded.occurredAt == derived.occurredAt
            && recorded.kind == derived.kind
            && recorded.output == derived.output
            && recorded.exitCode == derived.exitCode
            && recorded.terminationSignal == derived.terminationSignal
            && recorded.terminationReason == derived.terminationReason
            && recorded.cancellationIntent == derived.cancellationIntent
            && recorded.quarantinedByteCount == derived.quarantinedByteCount
    }

    private func journalState(executionID: RunBrokerExecutionID) throws -> JournalState {
        var result = JournalState()
        // Reconciliation runs once per active execution on every worker tick.
        // Use the durable execution/sequence index rather than multiplying a
        // full journal replay by every active execution.
        for observation in try ledger.supervisorObservations(for: executionID) {
            if result.observations[observation.supervisorSequence] != nil {
                throw RunBrokerServiceError.supervisorEventConflict(
                    sequence: observation.supervisorSequence
                )
            }
            result.observations[observation.supervisorSequence] = observation
            result.persistedOutputBytes += UInt64(observation.output?.count ?? 0)
            result.sawReady = result.sawReady || observation.kind == .supervisorReady
            result.sawProviderStarted = result.sawProviderStarted || observation.kind == .providerStarted
            result.sawCancellationConfirmed = result.sawCancellationConfirmed
                || observation.kind == .cancellationConfirmed
            result.terminal = result.terminal || [
                .providerExited, .providerLaunchFailed, .cancellationConfirmed,
            ].contains(observation.kind)
            result.terminalTailComplete = result.terminalTailComplete || [
                .providerExited, .providerLaunchFailed,
            ].contains(observation.kind)
        }
        if result.lastSequence > 0 {
            for expected in UInt64(1)...result.lastSequence {
                guard result.observations[expected] != nil else {
                    throw RunBrokerServiceError.nonContiguousSupervisorSequence(
                        expected: expected,
                        found: result.lastSequence
                    )
                }
            }
        }
        return result
    }

    private func observation(
        _ event: RunSupervisorEvent,
        identity: RunSupervisorIdentity,
        manifestCreatedAt: Date
    ) -> RunBrokerSupervisorObservation {
        .init(
            executionID: identity.executionID,
            authority: identity.authority,
            supervisorSequence: event.sequence,
            supervisorEventID: event.id,
            // The supervisor's clock may regress behind the app clock that
            // stamped the manifest. The ledger fails such evidence closed
            // (invalidEvent) and would wedge reconcile while the supervisor
            // keeps running; clamping to the immutable manifest instant is
            // deterministic across replays and mirrors markInDoubt's clamp.
            occurredAt: max(event.timestamp, manifestCreatedAt),
            kind: .init(rawValue: event.kind.rawValue)!,
            output: event.payload.data,
            exitCode: event.payload.exitCode,
            terminationSignal: event.payload.terminationSignal,
            terminationReason: event.payload.terminationReason.map {
                RunBrokerTerminationReason(rawValue: $0.rawValue)!
            },
            cancellationIntent: event.payload.cancellationIntent,
            quarantinedByteCount: event.payload.quarantinedByteCount
        )
    }

    private func supervisorEvent(
        from observation: RunBrokerSupervisorObservation
    ) -> RunSupervisorEvent {
        .init(
            sequence: observation.supervisorSequence,
            id: observation.supervisorEventID,
            timestamp: observation.occurredAt,
            kind: .init(rawValue: observation.kind.rawValue)!,
            payload: .init(
                data: observation.output,
                exitCode: observation.exitCode,
                cancellationIntent: observation.cancellationIntent,
                quarantinedByteCount: observation.quarantinedByteCount,
                terminationSignal: observation.terminationSignal,
                terminationReason: observation.terminationReason.map {
                    RunSupervisorTerminationReason(rawValue: $0.rawValue)!
                }
            )
        )
    }

    private func markInDoubt(
        identity: RunSupervisorIdentity,
        reason: String
    ) throws -> RunBrokerReconciliationOutcome {
        let execution = try ledger.projection().executions[identity.executionID]
        if execution?.control.observedExecution == .inDoubt {
            return .init(state: .inDoubt, lastSupervisorSequence: 0, replaySource: nil)
        }
        // The same failure reason can recur after authenticated evidence has
        // recovered the execution to running. Bind the identity to the
        // current durable state boundary so each uncertainty episode is a
        // distinct fact while retries within an unchanged episode remain
        // deterministic.
        let episodeSequence = execution?.updatedSequence ?? 0
        _ = try ledger.append(.init(
            eventID: deterministicEventID(
                identity.executionID.rawValue,
                domain: "in-doubt-\(reason)-after-\(episodeSequence)"
            ),
            occurredAt: max(Date(), execution?.updatedAt ?? Date()),
            event: .executionControlTransitioned(
                executionID: identity.executionID,
                authority: identity.authority,
                transition: .observationBecameIndeterminate,
                backendCapabilities: [.observe, .cancel]
            )
        ))
        logger.record(
            event: "run_broker.execution_in_doubt",
            fields: safeFields(identity).merging(["reason": reason]) { _, new in new }
        )
        return .init(state: .inDoubt, lastSupervisorSequence: 0, replaySource: nil)
    }

    private func deterministicEventID(_ seed: UUID, domain: String) -> RunLedgerEventID {
        var data = Data("astra.run-broker.event.v1\u{0}\(domain)\u{0}".utf8)
        withUnsafeBytes(of: seed.uuid) { data.append(contentsOf: $0) }
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return .init(rawValue: uuid)
    }

    private func safeFields(_ identity: RunSupervisorIdentity) -> [String: String] {
        [
            "execution_id": identity.executionID.rawValue.uuidString.lowercased(),
            "authority_epoch": String(identity.authority.epoch.rawValue),
        ]
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
