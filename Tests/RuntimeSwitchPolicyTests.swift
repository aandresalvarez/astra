import ASTRACore
import Foundation
import Testing

@Suite("Runtime configuration selection policy")
struct RuntimeConfigurationSelectionPolicyTests {
    @Test("Selecting runtime and model during an active execution changes only the next launch")
    func selectionDuringActiveExecutionDoesNotControlActiveRun() throws {
        let active = activeIdentity()
        let initial = NextExecutionRuntimeSelectionState(
            active: active,
            next: configuration(.claudeCode, model: "claude-current", revision: "next-1")
        )
        let selectedConfiguration = configuration(
            .copilotCLI,
            model: "gpt-next",
            revision: "next-2"
        )

        let reduction = NextExecutionRuntimeSelectionReducer.select(
            selectedConfiguration,
            in: initial
        )

        #expect(reduction.disposition == .applied)
        #expect(reduction.state.active == active)
        #expect(reduction.state.next == selectedConfiguration)
        #expect(reduction.state.active?.configuration.runtimeID == .claudeCode)
        #expect(reduction.state.active?.configuration.modelID == "claude-active")

        let replay = NextExecutionRuntimeSelectionReducer.select(
            selectedConfiguration,
            in: reduction.state
        )
        #expect(replay.disposition == .idempotent)
        #expect(replay.state == reduction.state)
    }

    @Test("Selection values normalize model and revision and reject an empty revision")
    func configurationNormalization() throws {
        let revision = try RuntimeConfigurationRevision(rawValue: "  revision-1  ")
        let value = RuntimeExecutionConfiguration(
            runtimeID: .codexCLI,
            modelID: "  gpt-5  ",
            revision: revision
        )
        #expect(value.modelID == "gpt-5")
        #expect(value.revision.rawValue == "revision-1")
        #expect(throws: RuntimeConfigurationContractError.emptyConfigurationRevision) {
            try RuntimeConfigurationRevision(rawValue: " \n ")
        }
    }
}

@Suite("Active runtime switch policy")
struct ActiveRuntimeSwitchPolicyTests {
    @Test("Default active switch is a graceful handoff pinned to the safe checkpoint")
    func defaultSwitchIsGraceful() throws {
        let context = safeContext()
        let intent = switchIntent(expected: context.identity)
        let request = ActiveRuntimeSwitchRequest.defaultHandoff(intent: intent)

        guard case .gracefulHandoff = request else {
            Issue.record("Default switch request must be graceful")
            return
        }
        let reduction = RuntimeSwitchPolicy.reduce(
            .empty,
            request: request,
            context: context
        )
        #expect(reduction.disposition == .applied)
        #expect(reduction.blockedReason == nil)
        #expect(reduction.state.accepted?.request == request)
        #expect(reduction.state.accepted?.acceptedCheckpointID == context.checkpoint.checkpointID)
        guard case .gracefulHandoff(let acceptedRequest, let checkpointID)? = reduction.directive else {
            Issue.record("Safe default must emit only a graceful handoff directive")
            return
        }
        #expect(acceptedRequest.intent == intent)
        #expect(checkpointID == context.checkpoint.checkpointID)
    }

    @Test("An accepted request replay is idempotent while request ID reuse with different intent is blocked")
    func requestIdempotencyAndConflict() throws {
        let context = safeContext()
        let request = ActiveRuntimeSwitchRequest.defaultHandoff(
            intent: switchIntent(expected: context.identity)
        )
        let first = RuntimeSwitchPolicy.reduce(.empty, request: request, context: context)
        let replay = RuntimeSwitchPolicy.reduce(first.state, request: request, context: context)
        #expect(replay.disposition == .idempotent)
        #expect(replay.state == first.state)
        #expect(replay.directive == first.directive)

        let reusedID = request.intent.requestID
        let changedIntent = switchIntent(
            requestID: reusedID,
            expected: context.identity,
            target: configuration(.cursorCLI, revision: "target-changed")
        )
        let conflict = RuntimeSwitchPolicy.reduce(
            first.state,
            request: .defaultHandoff(intent: changedIntent),
            context: context
        )
        #expect(conflict.disposition == .blocked)
        #expect(conflict.blockedReason == .requestIDConflict)
        #expect(conflict.state == first.state)
        #expect(conflict.directive == nil)
    }

    @Test("A second request cannot replace an already accepted switch")
    func acceptedSwitchCannotBeReplaced() throws {
        let context = safeContext()
        let first = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: context.identity)),
            context: context
        )
        let second = RuntimeSwitchPolicy.reduce(
            first.state,
            request: .defaultHandoff(intent: switchIntent(
                requestID: .init(rawValue: uuid(90)),
                expected: context.identity,
                target: configuration(.openCodeCLI, revision: "target-2")
            )),
            context: context
        )
        #expect(second.disposition == .blocked)
        #expect(second.blockedReason == .switchAlreadyPending)
        #expect(second.state == first.state)
    }

    @Test("Graceful handoff requires an observed checkpoint")
    func checkpointMustExist() throws {
        let context = switchContext(checkpointID: nil)
        let result = evaluateDefault(context)
        #expect(result.disposition == .blocked)
        #expect(result.blockedReason == .safeCheckpointUnavailable)
        #expect(result.directive == nil)
        #expect(result.state == .empty)
    }

    @Test("Any in-flight effect blocks graceful handoff even at a checkpoint")
    func inFlightEffectBlocksHandoff() throws {
        let context = switchContext(inFlightEffectCount: 1)
        let result = evaluateDefault(context)
        #expect(result.disposition == .blocked)
        #expect(result.blockedReason == .inFlightEffects)
        #expect(result.directive == nil)
    }

    @Test("Any in-flight tool operation blocks graceful handoff")
    func inFlightToolOperationBlocksHandoff() throws {
        let context = switchContext(inFlightToolOperationCount: 1)
        let result = evaluateDefault(context)
        #expect(result.disposition == .blocked)
        #expect(result.blockedReason == .inFlightToolOperations)
        #expect(result.directive == nil)
    }

    @Test(
        "Continuation support must be explicit on provider and supervisor",
        arguments: [
            (
                RuntimeContinuationCapabilityDeclaration.notDeclared,
                RuntimeContinuationCapabilityDeclaration.supported,
                RuntimeSwitchBlockedReason.providerContinuationNotDeclared
            ),
            (
                RuntimeContinuationCapabilityDeclaration.unsupported,
                RuntimeContinuationCapabilityDeclaration.supported,
                RuntimeSwitchBlockedReason.providerContinuationUnsupported
            ),
            (
                RuntimeContinuationCapabilityDeclaration.supported,
                RuntimeContinuationCapabilityDeclaration.notDeclared,
                RuntimeSwitchBlockedReason.supervisorContinuationNotDeclared
            ),
            (
                RuntimeContinuationCapabilityDeclaration.supported,
                RuntimeContinuationCapabilityDeclaration.unsupported,
                RuntimeSwitchBlockedReason.supervisorContinuationUnsupported
            )
        ]
    )
    func continuationMustBeExplicit(
        provider: RuntimeContinuationCapabilityDeclaration,
        supervisor: RuntimeContinuationCapabilityDeclaration,
        expectedReason: RuntimeSwitchBlockedReason
    ) throws {
        let context = switchContext(
            providerContinuation: provider,
            supervisorContinuation: supervisor
        )
        let result = evaluateDefault(context)
        #expect(result.disposition == .blocked)
        #expect(result.blockedReason == expectedReason)
        #expect(result.directive == nil)
    }

    @Test("Execution identity mismatch is rejected before any control directive")
    func staleExecutionIdentity() throws {
        let context = safeContext()
        let stale = ActiveRuntimeConfigurationIdentity(
            executionID: .init(rawValue: uuid(91)),
            authority: context.identity.authority,
            configuration: context.identity.configuration
        )
        let result = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: stale)),
            context: context
        )
        #expect(result.blockedReason == .executionIdentityMismatch)
        #expect(result.directive == nil)
    }

    @Test("Stale authority epoch is fenced even when execution identity matches")
    func staleAuthority() throws {
        let context = safeContext()
        let stale = ActiveRuntimeConfigurationIdentity(
            executionID: context.identity.executionID,
            authority: .init(
                id: context.identity.authority.id,
                epoch: .init(rawValue: context.identity.authority.epoch.rawValue - 1)
            ),
            configuration: context.identity.configuration
        )
        let result = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: stale)),
            context: context
        )
        #expect(result.blockedReason == .staleAuthority)
        #expect(result.directive == nil)
    }

    @Test("Stale active configuration revision is rejected deterministically")
    func staleConfigurationRevision() throws {
        let context = safeContext()
        let stale = ActiveRuntimeConfigurationIdentity(
            executionID: context.identity.executionID,
            authority: context.identity.authority,
            configuration: configuration(
                context.identity.configuration.runtimeID,
                model: context.identity.configuration.modelID,
                revision: "active-stale"
            )
        )
        let result = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: stale)),
            context: context
        )
        #expect(result.blockedReason == .staleConfigurationRevision)
        #expect(result.directive == nil)
    }

    @Test("Configuration payload mismatch cannot hide behind a reused revision")
    func activeConfigurationPayloadMismatch() throws {
        let context = safeContext()
        let mismatched = ActiveRuntimeConfigurationIdentity(
            executionID: context.identity.executionID,
            authority: context.identity.authority,
            configuration: configuration(
                .cursorCLI,
                model: "different-active-model",
                revision: context.identity.configuration.revision.rawValue
            )
        )
        let result = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: mismatched)),
            context: context
        )
        #expect(result.blockedReason == .activeConfigurationMismatch)
        #expect(result.directive == nil)
    }

    @Test("Terminal execution and no-op target are typed blocked results")
    func terminalAndNoOpAreBlocked() throws {
        let terminal = switchContext(lifecycle: .terminal)
        #expect(evaluateDefault(terminal).blockedReason == .executionNotActive)

        let active = safeContext()
        let noOp = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(
                expected: active.identity,
                target: active.identity.configuration
            )),
            context: active
        )
        #expect(noOp.blockedReason == .targetMatchesActiveConfiguration)
        #expect(noOp.directive == nil)
    }

    @Test("Force termination is separate and requires matching fresh confirmation")
    func forceRequiresConfirmation() throws {
        let unsafeContext = switchContext(
            checkpointID: nil,
            inFlightEffectCount: 3,
            providerContinuation: .unsupported,
            supervisorContinuation: .unsupported
        )
        let intent = switchIntent(expected: unsafeContext.identity)
        let audit = try RuntimeForceSwitchAudit(
            source: .runtimePicker,
            reasonCode: "user_force_switch"
        )
        let missing = ActiveRuntimeSwitchRequest.forceTermination(.init(
            intent: intent,
            audit: audit,
            confirmation: nil
        ))
        let missingResult = RuntimeSwitchPolicy.reduce(
            .empty,
            request: missing,
            context: unsafeContext
        )
        #expect(missingResult.blockedReason == .forceConfirmationRequired)
        #expect(missingResult.directive == nil)

        let wrongExecution = forceRequest(
            intent: intent,
            audit: audit,
            affirmedExecutionID: .init(rawValue: uuid(92)),
            confirmedAt: intent.requestedAt
        )
        #expect(RuntimeSwitchPolicy.reduce(
            .empty,
            request: wrongExecution,
            context: unsafeContext
        ).blockedReason == .forceConfirmationExecutionMismatch)

        let wrongRequest = forceRequest(
            intent: intent,
            audit: audit,
            affirmedRequestID: .init(rawValue: uuid(95)),
            affirmedExecutionID: intent.expectedActive.executionID,
            confirmedAt: intent.requestedAt
        )
        #expect(RuntimeSwitchPolicy.reduce(
            .empty,
            request: wrongRequest,
            context: unsafeContext
        ).blockedReason == .forceConfirmationRequestMismatch)

        let wrongTarget = forceRequest(
            intent: intent,
            audit: audit,
            affirmedExecutionID: intent.expectedActive.executionID,
            affirmedTarget: configuration(.cursorCLI, revision: "other-target"),
            confirmedAt: intent.requestedAt
        )
        #expect(RuntimeSwitchPolicy.reduce(
            .empty,
            request: wrongTarget,
            context: unsafeContext
        ).blockedReason == .forceConfirmationTargetMismatch)

        let staleConfirmation = forceRequest(
            intent: intent,
            audit: audit,
            affirmedExecutionID: intent.expectedActive.executionID,
            confirmedAt: intent.requestedAt.addingTimeInterval(-1)
        )
        #expect(RuntimeSwitchPolicy.reduce(
            .empty,
            request: staleConfirmation,
            context: unsafeContext
        ).blockedReason == .forceConfirmationPredatesRequest)

        let confirmed = forceRequest(
            intent: intent,
            audit: audit,
            affirmedExecutionID: intent.expectedActive.executionID,
            confirmedAt: intent.requestedAt
        )
        let accepted = RuntimeSwitchPolicy.reduce(
            .empty,
            request: confirmed,
            context: unsafeContext
        )
        #expect(accepted.disposition == .applied)
        #expect(accepted.blockedReason == nil)
        #expect(accepted.state.accepted?.acceptedCheckpointID == nil)
        guard case .forceTermination(let acceptedRequest)? = accepted.directive else {
            Issue.record("Only an explicitly confirmed force request may emit force termination")
            return
        }
        #expect(acceptedRequest.audit == audit)
        #expect(acceptedRequest.confirmation != nil)
    }

    @Test("Graceful request never escalates itself when checkpoint safety is absent")
    func gracefulNeverEscalatesToForce() throws {
        let context = switchContext(
            checkpointID: nil,
            inFlightEffectCount: 2,
            providerContinuation: .unsupported,
            supervisorContinuation: .unsupported
        )
        let result = evaluateDefault(context)
        #expect(result.disposition == .blocked)
        #expect(result.directive == nil)
        #expect(result.state.accepted == nil)
    }

    @Test(
        "Every built-in and extension runtime ID uses the same provider-neutral policy",
        arguments: [
            AgentRuntimeID.claudeCode,
            AgentRuntimeID.copilotCLI,
            AgentRuntimeID.antigravityCLI,
            AgentRuntimeID.codexCLI,
            AgentRuntimeID.cursorCLI,
            AgentRuntimeID.openCodeCLI,
            AgentRuntimeID(rawValue: "future_remote_provider")!
        ]
    )
    func runtimeIDsAreProviderNeutral(runtimeID: AgentRuntimeID) throws {
        let context = safeContext()
        let target = configuration(
            runtimeID,
            model: "provider-neutral-model",
            revision: "target-\(runtimeID.rawValue)"
        )
        let result = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(
                expected: context.identity,
                target: target
            )),
            context: context
        )
        #expect(result.disposition == .applied)
        guard case .gracefulHandoff(let request, _)? = result.directive else {
            Issue.record("Every runtime must produce the same graceful directive")
            return
        }
        #expect(request.intent.target.runtimeID == runtimeID)
    }

    @Test("Force reason is mandatory")
    func forceReasonRequired() {
        #expect(throws: RuntimeSwitchContractError.emptyForceReasonCode) {
            try RuntimeForceSwitchAudit(source: .diagnostics, reasonCode: "  ")
        }
    }
}

@Suite("Runtime switch strict wire contracts")
struct RuntimeSwitchStrictWireContractTests {
    @Test("Graceful and force requests round-trip with exact variant")
    func requestRoundTrip() throws {
        let context = safeContext()
        let graceful = ActiveRuntimeSwitchRequest.defaultHandoff(
            intent: switchIntent(expected: context.identity)
        )
        let gracefulData = try JSONEncoder().encode(graceful)
        #expect(try JSONDecoder().decode(ActiveRuntimeSwitchRequest.self, from: gracefulData) == graceful)

        let intent = switchIntent(
            requestID: .init(rawValue: uuid(93)),
            expected: context.identity
        )
        let audit = try RuntimeForceSwitchAudit(source: .diagnostics, reasonCode: "provider_stuck")
        let force = forceRequest(
            intent: intent,
            audit: audit,
            affirmedExecutionID: context.identity.executionID,
            confirmedAt: intent.requestedAt
        )
        let forceData = try JSONEncoder().encode(force)
        #expect(try JSONDecoder().decode(ActiveRuntimeSwitchRequest.self, from: forceData) == force)
    }

    @Test("Unknown nested target fields and incompatible schema versions fail closed")
    func nestedUnknownKeysAndVersionFailClosed() throws {
        let context = safeContext()
        let request = ActiveRuntimeSwitchRequest.defaultHandoff(
            intent: switchIntent(expected: context.identity)
        )
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var graceful = try #require(object["gracefulHandoff"] as? [String: Any])
        var intent = try #require(graceful["intent"] as? [String: Any])
        var target = try #require(intent["target"] as? [String: Any])
        target["fallbackRuntimeID"] = "local_provider"
        intent["target"] = target
        graceful["intent"] = intent
        object["gracefulHandoff"] = graceful
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Noncanonical nested runtime values fail closed instead of normalizing on the wire")
    func noncanonicalRuntimeValuesFailClosed() throws {
        let context = safeContext()
        let request = ActiveRuntimeSwitchRequest.defaultHandoff(
            intent: switchIntent(expected: context.identity)
        )
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var graceful = try #require(object["gracefulHandoff"] as? [String: Any])
        var intent = try #require(graceful["intent"] as? [String: Any])
        var target = try #require(intent["target"] as? [String: Any])
        target["runtimeID"] = "  \(AgentRuntimeID.codexCLI.rawValue)  "
        intent["target"] = target
        graceful["intent"] = intent
        object["gracefulHandoff"] = graceful
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Wire variant cannot smuggle both graceful and force payloads")
    func variantMustBeExclusive() throws {
        let context = safeContext()
        let graceful = ActiveRuntimeSwitchRequest.defaultHandoff(
            intent: switchIntent(expected: context.identity)
        )
        let forceIntent = switchIntent(
            requestID: .init(rawValue: uuid(94)),
            expected: context.identity
        )
        let force = forceRequest(
            intent: forceIntent,
            audit: try .init(source: .automation, reasonCode: "test"),
            affirmedExecutionID: context.identity.executionID,
            confirmedAt: forceIntent.requestedAt
        )
        var gracefulObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(graceful)) as? [String: Any]
        )
        let forceObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(force)) as? [String: Any]
        )
        gracefulObject["forceTermination"] = forceObject["forceTermination"]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: gracefulObject)
            )
        }
    }

    @Test("Accepted policy state round-trips and rejects unknown state fields")
    func stateRoundTripAndStrictness() throws {
        let context = safeContext()
        let accepted = RuntimeSwitchPolicy.reduce(
            .empty,
            request: .defaultHandoff(intent: switchIntent(expected: context.identity)),
            context: context
        ).state
        let encoded = try JSONEncoder().encode(accepted)
        #expect(try JSONDecoder().decode(RuntimeSwitchPolicyState.self, from: encoded) == accepted)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["processIdentifier"] = 1234
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Accepted force state rejects a confirmation that no longer binds its target")
    func acceptedForceStateRejectsTamperedConfirmation() throws {
        let context = switchContext(checkpointID: nil)
        let intent = switchIntent(expected: context.identity)
        let request = forceRequest(
            intent: intent,
            audit: try .init(source: .diagnostics, reasonCode: "confirmed_force"),
            affirmedExecutionID: context.identity.executionID,
            confirmedAt: intent.requestedAt
        )
        let accepted = RuntimeSwitchPolicy.reduce(
            .empty,
            request: request,
            context: context
        ).state
        let encoded = try JSONEncoder().encode(accepted)
        var state = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var acceptedObject = try #require(state["accepted"] as? [String: Any])
        var requestEnvelope = try #require(acceptedObject["request"] as? [String: Any])
        var force = try #require(requestEnvelope["forceTermination"] as? [String: Any])
        var confirmation = try #require(force["confirmation"] as? [String: Any])
        var target = try #require(confirmation["affirmedTarget"] as? [String: Any])
        target["runtimeID"] = AgentRuntimeID.cursorCLI.rawValue
        confirmation["affirmedTarget"] = target
        force["confirmation"] = confirmation
        requestEnvelope["forceTermination"] = force
        acceptedObject["request"] = requestEnvelope
        state["accepted"] = acceptedObject

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: state)
            )
        }
    }
}

private let switchTestDate = Date(timeIntervalSince1970: 1_800_000_000)

private func uuid(_ seed: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!
}

private func configuration(
    _ runtimeID: AgentRuntimeID,
    model: String? = nil,
    revision: String
) -> RuntimeExecutionConfiguration {
    RuntimeExecutionConfiguration(
        runtimeID: runtimeID,
        modelID: model,
        revision: try! RuntimeConfigurationRevision(rawValue: revision)
    )
}

private func activeIdentity() -> ActiveRuntimeConfigurationIdentity {
    .init(
        executionID: .init(rawValue: uuid(1)),
        authority: .init(
            id: .init(rawValue: uuid(2)),
            epoch: .init(rawValue: 3)
        ),
        configuration: configuration(
            .claudeCode,
            model: "claude-active",
            revision: "active-3"
        )
    )
}

private func switchContext(
    lifecycle: RuntimeSwitchExecutionLifecycle = .active,
    checkpointID: RuntimeSwitchCheckpointID? = try! .init(rawValue: "checkpoint-4"),
    inFlightEffectCount: UInt = 0,
    inFlightToolOperationCount: UInt = 0,
    providerContinuation: RuntimeContinuationCapabilityDeclaration = .supported,
    supervisorContinuation: RuntimeContinuationCapabilityDeclaration = .supported
) -> ActiveRuntimeSwitchContext {
    .init(
        identity: activeIdentity(),
        lifecycle: lifecycle,
        checkpoint: .init(
            checkpointID: checkpointID,
            inFlightEffectCount: inFlightEffectCount,
            inFlightToolOperationCount: inFlightToolOperationCount,
            providerContinuation: providerContinuation,
            supervisorContinuation: supervisorContinuation
        )
    )
}

private func safeContext() -> ActiveRuntimeSwitchContext {
    switchContext()
}

private func switchIntent(
    requestID: RuntimeSwitchRequestID = .init(rawValue: uuid(5)),
    expected: ActiveRuntimeConfigurationIdentity,
    target: RuntimeExecutionConfiguration = configuration(
        .codexCLI,
        model: "gpt-target",
        revision: "target-6"
    )
) -> RuntimeSwitchIntent {
    .init(
        requestID: requestID,
        expectedActive: expected,
        target: target,
        requestedAt: switchTestDate
    )
}

private func evaluateDefault(
    _ context: ActiveRuntimeSwitchContext
) -> RuntimeSwitchPolicyReduction {
    RuntimeSwitchPolicy.reduce(
        .empty,
        request: .defaultHandoff(intent: switchIntent(expected: context.identity)),
        context: context
    )
}

private func forceRequest(
    intent: RuntimeSwitchIntent,
    audit: RuntimeForceSwitchAudit,
    affirmedRequestID: RuntimeSwitchRequestID? = nil,
    affirmedExecutionID: RunBrokerExecutionID,
    affirmedTarget: RuntimeExecutionConfiguration? = nil,
    confirmedAt: Date
) -> ActiveRuntimeSwitchRequest {
    .forceTermination(.init(
        intent: intent,
        audit: audit,
        confirmation: .init(
            confirmationID: uuid(7),
            affirmedRequestID: affirmedRequestID ?? intent.requestID,
            affirmedExecutionID: affirmedExecutionID,
            affirmedTarget: affirmedTarget ?? intent.target,
            affirmation: .terminateActiveExecutionImmediately,
            confirmedAt: confirmedAt
        )
    ))
}
