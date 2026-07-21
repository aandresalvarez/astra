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
        var terminal = false

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

            if existing == nil {
                try vault.persistAndSynchronize(.init(
                    identity: identity,
                    manifestSHA256: digest,
                    capability: capability,
                    launchMaterialAuthenticator: launchMaterialAuthenticator
                ))
            }
            try faultInjector.checkpoint(.afterCapabilitySync)

            let admission = try ledger.admitExecution(
                manifest: request.manifest,
                primaryOperationID: request.primaryOperationID,
                admittedAt: request.manifest.createdAt,
                idempotencyKey: request.admissionID
            )
            try faultInjector.checkpoint(.afterLedgerAdmission)

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
            try reconcileLocked(executionID: executionID, startFaultsEnabled: false)
        }
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
                    occurredAt: requestedAt,
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
        let identity = RunSupervisorIdentity(
            installationID: execution.manifest.installationID,
            storeID: execution.manifest.storeID,
            executionID: executionID,
            authority: execution.authority
        )
        guard let capability = try vault.load(executionID: executionID) else {
            return try markInDoubt(identity: identity, reason: "missing_capability")
        }
        guard capability.identity == identity,
              capability.manifestSHA256 == (try RunSupervisorDigests.manifest(execution.manifest)) else {
            return try markInDoubt(identity: identity, reason: "capability_identity_mismatch")
        }
        guard let policy = execution.manifest.supervisionPolicy else {
            return try markInDoubt(identity: identity, reason: "missing_policy")
        }

        var state = try journalState(executionID: executionID)
        // A crash may commit an authenticated observation but not its derived
        // execution-control transition. Repair from canonical journal truth
        // before asking the supervisor for events after the durable cursor.
        for observation in state.observations.values.sorted(by: {
            $0.supervisorSequence < $1.supervisorSequence
        }) {
            try ensureDerivedControl(
                for: supervisorEvent(from: observation),
                identity: identity,
                state: &state
            )
        }
        var lastSource: RunBrokerSupervisorReplaySource?
        var acknowledgedThisPass: UInt64 = 0
        do {
            while true {
                let batch = try transport.replay(
                    identity: identity,
                    capability: capability.capability,
                    after: state.lastSequence
                )
                guard batch.identity == identity else {
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
                            identity: identity,
                            capability: capability.capability,
                            source: batch.source,
                            through: state.lastSequence
                        )
                        acknowledgedThisPass = state.lastSequence
                    }
                    break
                }
                for event in batch.events {
                    try persist(
                        event,
                        identity: identity,
                        policy: policy,
                        state: &state,
                        startFaultsEnabled: startFaultsEnabled
                    )
                }
                try transport.acknowledge(
                    identity: identity,
                    capability: capability.capability,
                    source: batch.source,
                    through: state.lastSequence
                )
                acknowledgedThisPass = state.lastSequence
                if state.terminal { break }
            }
        } catch let error as RunBrokerServiceError {
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
            return try markInDoubt(identity: identity, reason: "authentication_failed")
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

    private func persist(
        _ event: RunSupervisorEvent,
        identity: RunSupervisorIdentity,
        policy: ExecutionSupervisionPolicySnapshot,
        state: inout JournalState,
        startFaultsEnabled: Bool
    ) throws {
        if let existing = state.observations[event.sequence] {
            let requested = observation(event, identity: identity)
            guard existing == requested else {
                throw RunBrokerServiceError.supervisorEventConflict(sequence: event.sequence)
            }
            try ensureDerivedControl(for: event, identity: identity, state: &state)
            return
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
        if let output = event.payload.data {
            let outputBytes = UInt64(output.count)
            guard outputBytes <= policy.maximumOutputEventBytes,
                  outputBytes <= policy.maximumPersistedOutputBytes,
                  state.persistedOutputBytes <= policy.maximumPersistedOutputBytes - outputBytes else {
                throw RunBrokerServiceError.outputLimitExceeded(
                    limit: policy.maximumPersistedOutputBytes
                )
            }
        }

        let durable = observation(event, identity: identity)
        _ = try ledger.append(.init(
            eventID: deterministicEventID(event.id, domain: "supervisor-observation"),
            occurredAt: event.timestamp,
            event: .supervisorObservationRecorded(durable)
        ))
        state.observations[event.sequence] = durable
        state.persistedOutputBytes += UInt64(event.payload.data?.count ?? 0)
        if event.kind == .supervisorReady {
            state.sawReady = true
            if startFaultsEnabled { try faultInjector.checkpoint(.afterReadyEvidence) }
        }
        if event.kind == .providerStarted {
            state.sawProviderStarted = true
            try faultInjector.checkpoint(.afterProviderStartedObservation)
            try appendControl(
                .executionStarted,
                identity: identity,
                event: event,
                domain: "execution-started"
            )
            if startFaultsEnabled { try faultInjector.checkpoint(.afterProviderStartedEvidence) }
        }
        if event.kind.isTerminalTruth {
            try faultInjector.checkpoint(.afterTerminalObservation)
        }
        try ensureDerivedControl(for: event, identity: identity, state: &state)
        logger.record(
            event: "run_broker.supervisor_event_durable",
            fields: safeFields(identity).merging([
                "sequence": String(event.sequence),
                "kind": event.kind.rawValue,
            ]) { _, new in new }
        )
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
        case .providerExited:
            try appendControl(
                event.payload.exitCode == 0 ? .executionCompleted : .executionFailed,
                identity: identity,
                event: event,
                domain: "execution-exited"
            )
            state.terminal = true
        case .cancellationConfirmed:
            try appendControl(
                .cancellationConfirmed,
                identity: identity,
                event: event,
                domain: "cancellation-confirmed"
            )
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
        _ = try ledger.append(.init(
            eventID: deterministicEventID(event.id, domain: domain),
            occurredAt: event.timestamp,
            event: .executionControlTransitioned(
                executionID: identity.executionID,
                authority: identity.authority,
                transition: transition,
                backendCapabilities: [.observe, .cancel]
            )
        ))
    }

    private func journalState(executionID: RunBrokerExecutionID) throws -> JournalState {
        var result = JournalState()
        var cursor: Int64 = 0
        while true {
            let events = try ledger.events(after: cursor, limit: 1_000)
            guard !events.isEmpty else { break }
            for stored in events {
                cursor = stored.sequence
                guard case .supervisorObservationRecorded(let observation) = stored.envelope.event,
                      observation.executionID == executionID else { continue }
                if result.observations[observation.supervisorSequence] != nil {
                    throw RunBrokerServiceError.supervisorEventConflict(
                        sequence: observation.supervisorSequence
                    )
                }
                result.observations[observation.supervisorSequence] = observation
                result.persistedOutputBytes += UInt64(observation.output?.count ?? 0)
                result.sawReady = result.sawReady || observation.kind == .supervisorReady
                result.sawProviderStarted = result.sawProviderStarted || observation.kind == .providerStarted
                result.terminal = result.terminal || [
                    .providerExited, .providerLaunchFailed, .cancellationConfirmed,
                ].contains(observation.kind)
            }
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
        identity: RunSupervisorIdentity
    ) -> RunBrokerSupervisorObservation {
        .init(
            executionID: identity.executionID,
            authority: identity.authority,
            supervisorSequence: event.sequence,
            supervisorEventID: event.id,
            occurredAt: event.timestamp,
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
        _ = try ledger.append(.init(
            eventID: deterministicEventID(identity.executionID.rawValue, domain: "in-doubt-\(reason)"),
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
