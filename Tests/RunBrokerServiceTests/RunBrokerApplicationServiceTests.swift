import ASTRACore
import ASTRARunLedger
import Darwin
import Foundation
import RunBrokerKit
import RunBrokerPolicy
import RunSupervisorSupport
import Testing
@testable import RunBrokerService

private func applicationDraft(
    from manifest: ExecutionLaunchManifest
) -> RunBrokerApplicationLaunchDraft {
    .init(
        executionID: manifest.executionID,
        taskID: manifest.taskID,
        configuration: manifest.configuration,
        declaredEffects: manifest.declaredEffects,
        supervisionPolicy: manifest.supervisionPolicy!,
        createdAt: manifest.createdAt
    )
}

@Suite("RunBroker application control plane", .serialized)
struct RunBrokerApplicationServiceTests {
    @Test("new runtime-switch admission rejects sub-millisecond, future, and stale mutation time")
    func runtimeSwitchMutationTimeIsCanonicalAndFresh() throws {
        let submillisecond = try BrokerFixture()
        let submillisecondSubmission = try runtimeSwitchSubmission(
            fixture: submillisecond,
            requestID: .init(rawValue: brokerUUID(155)),
            targetExecutionID: .init(rawValue: brokerUUID(156)),
            requestedAt: brokerTestDate.addingTimeInterval(0.000_5)
        )
        #expect(throws: RunBrokerApplicationContractError.invalidRuntimeSwitch) {
            try submillisecondSubmission.validate()
        }

        let malformedTargetFixture = try BrokerFixture()
        try malformedTargetFixture.admitOnly()
        let validSubmission = try runtimeSwitchSubmission(
            fixture: malformedTargetFixture,
            requestID: .init(rawValue: brokerUUID(163)),
            targetExecutionID: .init(rawValue: brokerUUID(164)),
            requestedAt: brokerTestDate
        )
        let malformedTarget = RunBrokerApplicationLaunchDraft(
            executionID: validSubmission.targetDraft.executionID,
            taskID: validSubmission.targetDraft.taskID,
            configuration: .init(
                runtimeID: .claudeCode,
                executablePath: "relative/not-executable",
                workingDirectory: "/tmp",
                configurationRevision: "runtime-switch-malformed-target"
            ),
            declaredEffects: validSubmission.targetDraft.declaredEffects,
            supervisionPolicy: validSubmission.targetDraft.supervisionPolicy,
            createdAt: validSubmission.targetDraft.createdAt
        )
        let malformedSubmission = RunBrokerApplicationRuntimeSwitchSubmission(
            requestID: validSubmission.requestID,
            mode: validSubmission.mode,
            expectedSource: validSubmission.expectedSource,
            targetDraft: malformedTarget,
            requestedAt: validSubmission.requestedAt,
            forceAudit: validSubmission.forceAudit,
            targetProtocol: validSubmission.targetProtocol,
            actorID: validSubmission.actorID,
            sessionID: validSubmission.sessionID
        )
        let malformedService = RunBrokerApplicationService(
            ledger: malformedTargetFixture.ledger,
            orchestrator: malformedTargetFixture.orchestrator(),
            vault: malformedTargetFixture.vault,
            runtimeSwitchBackend: ImmediateAdmissionOnlyRuntimeSwitchBackend()
        )
        let beforeMalformed = try malformedTargetFixture.ledger.events(limit: 100)
        #expect(throws: RunBrokerApplicationContractError.invalidManifestMetadata) {
            _ = try malformedService.handle(
                .requestImmediateRuntimeSwitchChallenge(malformedSubmission),
                idempotencyKey: brokerUUID(165),
                now: brokerTestDate
            )
        }
        #expect(try malformedTargetFixture.ledger.events(limit: 100) == beforeMalformed)

        for (index, requestedAt) in [
            brokerTestDate.addingTimeInterval(5 * 60 + 1),
            brokerTestDate.addingTimeInterval(-(5 * 60 + 1)),
        ].enumerated() {
            let fixture = try BrokerFixture()
            try fixture.admitOnly()
            let before = try fixture.ledger.events(limit: 100)
            let submission = try runtimeSwitchSubmission(
                fixture: fixture,
                requestID: .init(rawValue: brokerUUID(UInt8(157 + index * 2))),
                targetExecutionID: .init(rawValue: brokerUUID(UInt8(158 + index * 2))),
                requestedAt: requestedAt
            )
            let service = RunBrokerApplicationService(
                ledger: fixture.ledger,
                orchestrator: fixture.orchestrator(),
                vault: fixture.vault,
                runtimeSwitchBackend: ImmediateAdmissionOnlyRuntimeSwitchBackend()
            )
            #expect(throws: RunBrokerApplicationEndpointError.requestRejected) {
                _ = try service.handle(
                    .requestImmediateRuntimeSwitchChallenge(submission),
                    idempotencyKey: brokerUUID(UInt8(162 + index)),
                    now: brokerTestDate
                )
            }
            #expect(try fixture.ledger.events(limit: 100) == before)
        }
    }

    @Test("lost runtime-switch response retries with identical durable challenge at a later clock")
    func runtimeSwitchLostResponseRetryIsTimeStable() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let source = try RuntimeSwitchSourceFence(
            manifest: fixture.manifest,
            manifestSHA256: RuntimeSwitchDigests.manifest(fixture.manifest)
        )
        let targetDraft = RunBrokerApplicationLaunchDraft(
            executionID: .init(rawValue: brokerUUID(150)),
            taskID: fixture.manifest.taskID,
            configuration: .init(
                runtimeID: .claudeCode,
                executablePath: "/usr/bin/true",
                workingDirectory: "/tmp",
                configurationRevision: "runtime-switch-target"
            ),
            declaredEffects: fixture.manifest.declaredEffects,
            supervisionPolicy: fixture.manifest.supervisionPolicy!,
            createdAt: brokerTestDate
        )
        let requestID = RuntimeSwitchRequestID(rawValue: brokerUUID(151))
        let submission = RunBrokerApplicationRuntimeSwitchSubmission(
            requestID: requestID,
            mode: .immediate,
            expectedSource: source,
            targetDraft: targetDraft,
            requestedAt: brokerTestDate,
            forceAudit: .init(
                auditID: .init(rawValue: brokerUUID(152)),
                source: .diagnostics,
                reasonCode: .operatorEmergencyStop
            ),
            targetProtocol: .baseline,
            actorID: try .init(rawValue: "operator-1"),
            sessionID: brokerUUID(153)
        )
        let service = RunBrokerApplicationService(
            ledger: fixture.ledger,
            orchestrator: fixture.orchestrator(),
            vault: fixture.vault,
            runtimeSwitchBackend: ImmediateAdmissionOnlyRuntimeSwitchBackend()
        )
        let command = RunBrokerApplicationCommand.requestImmediateRuntimeSwitchChallenge(submission)
        let first = try service.handle(
            command,
            idempotencyKey: brokerUUID(154),
            now: brokerTestDate
        )
        let events = try fixture.ledger.events(limit: 100)
        let replay = try service.handle(
            command,
            idempotencyKey: brokerUUID(154),
            now: brokerTestDate.addingTimeInterval(10 * 60)
        )
        #expect(replay == first)
        #expect(try fixture.ledger.events(limit: 100) == events)
        #expect(try fixture.ledger.projection().runtimeSwitchPolicyState.record?
            .forceChallenge?.issuedAt == brokerTestDate)
    }

    @Test("production broker context advertises only end-to-end runtime features")
    func brokerContextDoesNotOverclaimRuntimeControl() throws {
        let fixture = try BrokerFixture()
        let service = applicationService(fixture)
        guard case .brokerContext(let context) = try service.handle(
            .brokerContext,
            idempotencyKey: brokerUUID(116),
            now: brokerTestDate
        ) else {
            Issue.record("Expected broker context")
            return
        }
        #expect(context.installationID == fixture.ledger.identity.installationID)
        #expect(context.storeID == fixture.ledger.identity.storeID)
        #expect(context.runtimeFeatures == [.durableTypedStream])
        #expect(!context.runtimeFeatures.contains(.gracefulCancellation))
        #expect(!context.runtimeFeatures.contains(.safeRuntimeHandoff))
        #expect(!context.runtimeFeatures.contains(.immediateTermination))
    }

    @Test("start rejects runtime features the production broker does not advertise")
    func startRejectsUnsupportedRuntimeFeatures() throws {
        let fixture = try BrokerFixture()
        let service = applicationService(fixture)
        let overclaimed = try RunBrokerRuntimeProtocolManifest(
            supervisorProtocolVersion: 2,
            providerAdapterID: "provider-neutral-v2",
            providerAdapterProtocolVersion: 2,
            features: [.durableTypedStream, .normalizedEvents, .standardInput]
        )
        let start = RunBrokerApplicationStartRequest(
            taskRunID: fixture.manifest.executionID.rawValue,
            draft: applicationDraft(from: fixture.manifest),
            primaryOperationID: fixture.request().primaryOperationID,
            runtimeProtocol: overclaimed,
            arguments: [],
            environment: [:]
        )

        #expect(throws: RunBrokerApplicationContractError.invalidManifestMetadata) {
            _ = try service.handle(
                .start(start),
                idempotencyKey: brokerUUID(117),
                now: brokerTestDate
            )
        }
        #expect(try fixture.ledger.events().isEmpty)
        #expect(fixture.vault.persistCount == 0)
        #expect(fixture.spawner.payloads.isEmpty)
    }

    @Test("unsupported graceful and standard-input commands remain unavailable without mutation")
    func unsupportedExecutionCommandsRemainUnavailable() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let authority = try currentAuthority(fixture)
        let fence = RunBrokerApplicationExecutionFence(
            executionID: fixture.manifest.executionID,
            authority: authority,
            expectedSupervisorSequence: 2
        )
        let before = try fixture.ledger.events(limit: 100)

        #expect(throws: RunBrokerApplicationEndpointError.externalOperationBlocked) {
            _ = try service.handle(
                .cancelExecution(.init(fence: fence)),
                idempotencyKey: brokerUUID(135),
                now: brokerTestDate.addingTimeInterval(3)
            )
        }
        #expect(throws: RunBrokerApplicationEndpointError.externalOperationBlocked) {
            _ = try service.handle(
                .writeStandardInput(try .init(fence: fence, line: "status")),
                idempotencyKey: brokerUUID(136),
                now: brokerTestDate.addingTimeInterval(3)
            )
        }
        #expect(throws: RunBrokerApplicationEndpointError.externalOperationBlocked) {
            _ = try service.handle(
                .closeStandardInput(fence),
                idempotencyKey: brokerUUID(137),
                now: brokerTestDate.addingTimeInterval(3)
            )
        }
        #expect(try fixture.ledger.events(limit: 100) == before)
        #expect(fixture.transport.immediateTerminationCount == 0)
    }

    @Test("start inside the supervisor bootstrap window is admitted, not an application rejection")
    func startDuringSupervisorBootstrapWindowIsAdmitted() throws {
        let fixture = try BrokerFixture()
        // Production launch window: the spawner has returned but the
        // supervisor child has not created its execution directory yet, so
        // the Darwin transport raises the typed ENOENT absence signal.
        fixture.transport.replayError = RunSupervisorError.systemCall(
            "openat execution directory", ENOENT
        )
        let service = applicationService(fixture)
        let response = try service.handle(
            .start(.init(
                taskRunID: fixture.manifest.executionID.rawValue,
                draft: applicationDraft(from: fixture.manifest),
                primaryOperationID: fixture.request().primaryOperationID,
                arguments: [],
                environment: [:]
            )),
            idempotencyKey: brokerUUID(198),
            now: brokerTestDate
        )
        guard case .executionStatus(let status) = response else {
            Issue.record("Expected an admitted execution status, not a rejection")
            return
        }
        #expect(status.state == .admitted)
        #expect(status.lastSupervisorSequence == 0)
        try status.validate()
        #expect(fixture.spawner.payloads.count == 1)

        // Once the supervisor publishes evidence, broker-owned
        // reconciliation observes it by identity without a second launch.
        fixture.transport.replayError = nil
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let reconciled = try service.handle(
            .reconcile(fixture.manifest.executionID),
            idempotencyKey: brokerUUID(199),
            now: brokerTestDate.addingTimeInterval(1)
        )
        guard case .executionStatus(let running) = reconciled else {
            Issue.record("Expected a running execution status after evidence")
            return
        }
        #expect(running.state == .running)
        #expect(fixture.spawner.payloads.count == 1)
    }

    @Test("task-run identity is exact and a replay is ledger-idempotent")
    func startIdentityAndDurableIdempotency() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = applicationService(fixture)
        let manifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            taskID: fixture.manifest.taskID,
            authority: fixture.manifest.authority,
            configuration: .init(
                runtimeID: fixture.manifest.configuration.runtimeID,
                modelID: fixture.manifest.configuration.modelID,
                executablePath: fixture.manifest.configuration.executablePath,
                launchArguments: fixture.manifest.configuration.launchArguments,
                workingDirectory: fixture.manifest.configuration.workingDirectory,
                environmentVariableNames: ["LANG"],
                configurationRevision: fixture.manifest.configuration.configurationRevision
            ),
            declaredEffects: fixture.manifest.declaredEffects,
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: fixture.manifest.createdAt
        )
        let start = RunBrokerApplicationStartRequest(
            taskRunID: manifest.executionID.rawValue,
            draft: applicationDraft(from: manifest),
            primaryOperationID: fixture.request().primaryOperationID,
            arguments: [],
            environment: ["LANG": "en_US.UTF-8"]
        )
        let key = brokerUUID(81)
        let first = try service.handle(.start(start), idempotencyKey: key, now: brokerTestDate)
        let firstEvents = try fixture.ledger.events(limit: 100)
        let replay = try service.handle(.start(start), idempotencyKey: key, now: brokerTestDate)

        #expect(first == replay)
        guard case .executionStatus(let firstStatus) = first,
              case .executionStatus(let replayStatus) = replay else {
            Issue.record("Expected broker-minted execution status")
            return
        }
        #expect(firstStatus.authority.epoch == .initial)
        #expect(firstStatus.authority == replayStatus.authority)
        #expect(firstStatus.authority != manifest.authority)
        try firstStatus.validate()
        #expect(try fixture.ledger.events(limit: 100) == firstEvents)
        #expect(fixture.spawner.payloads.count == 1)
        #expect(fixture.spawner.payloads.allSatisfy { $0.arguments.isEmpty })

        let wrongIdentity = RunBrokerApplicationStartRequest(
            taskRunID: brokerUUID(99),
            draft: applicationDraft(from: manifest),
            primaryOperationID: fixture.request().primaryOperationID,
            arguments: [],
            environment: [:]
        )
        #expect(throws: RunBrokerApplicationContractError.taskRunIdentityMismatch) {
            _ = try service.handle(
                .start(wrongIdentity),
                idempotencyKey: brokerUUID(82),
                now: brokerTestDate
            )
        }
        #expect(try fixture.ledger.events(limit: 100) == firstEvents)

        let changedSecrets = RunBrokerApplicationStartRequest(
            taskRunID: manifest.executionID.rawValue,
            draft: applicationDraft(from: manifest),
            primaryOperationID: fixture.request().primaryOperationID,
            arguments: [],
            environment: ["LANG": "changed-secret-value"]
        )
        #expect(throws: RunBrokerServiceError.launchMaterialConflict) {
            _ = try service.handle(.start(changedSecrets), idempotencyKey: key, now: brokerTestDate)
        }
        #expect(fixture.vault.persistCount == 1)
        #expect(fixture.spawner.payloads.count == 1)

        let diagnosticRequest = RunBrokerStartRequest(
            authorityMode: .durableBroker,
            manifest: manifest,
            primaryOperationID: fixture.request().primaryOperationID,
            admissionID: brokerUUID(94),
            arguments: ["diagnostic-argument-secret"],
            environment: ["TOKEN": "diagnostic-environment-secret"]
        )
        #expect(!String(describing: diagnosticRequest).contains("diagnostic-argument-secret"))
        #expect(!String(reflecting: diagnosticRequest).contains("diagnostic-environment-secret"))

        let conflictingManifest = ExecutionLaunchManifest(
            installationID: manifest.installationID,
            storeID: manifest.storeID,
            executionID: .init(rawValue: brokerUUID(97)),
            taskID: brokerUUID(96),
            authority: manifest.authority,
            configuration: manifest.configuration,
            declaredEffects: manifest.declaredEffects,
            supervisionPolicy: manifest.supervisionPolicy,
            createdAt: manifest.createdAt
        )
        let reusedKey = RunBrokerApplicationStartRequest(
            taskRunID: conflictingManifest.executionID.rawValue,
            draft: applicationDraft(from: conflictingManifest),
            primaryOperationID: .init(rawValue: brokerUUID(95)),
            arguments: [],
            environment: ["LANG": "en_US.UTF-8"]
        )
        #expect(throws: RunBrokerServiceError.idempotencyKeyConflict) {
            _ = try service.handle(.start(reusedKey), idempotencyKey: key, now: brokerTestDate)
        }
        #expect(fixture.vault.persistCount == 1)
        #expect(fixture.spawner.payloads.count == 1)
    }

    @Test("Signed semantically invalid launch requests fail before every durable or provider effect")
    func signedInvalidLaunchHasZeroMutation() throws {
        let fixture = try BrokerFixture()
        let service = applicationService(fixture)
        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 0xA5, count: 32))
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secret,
            random: BrokerWireSequenceRandom()
        )
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: fixture.manifest.installationID,
            brokerVersion: "signed-invalid-test",
            authenticator: authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: .init(
                ledger: UnavailableRunBrokerMonitorLedger(),
                monitor: UnavailableRunBrokerExternalOperationMonitor()
            ),
            applicationHandler: service
        )
        let wire = RunBrokerWireCodec()

        func response(
            manifest: ExecutionLaunchManifest,
            requestID: UUID,
            idempotencyKey: UUID
        ) throws -> RunBrokerResponseEnvelope {
            let start = RunBrokerApplicationStartRequest(
                taskRunID: manifest.executionID.rawValue,
                draft: applicationDraft(from: manifest),
                primaryOperationID: fixture.request().primaryOperationID,
                arguments: [],
                environment: [:]
            )
            let signed = try authenticator.authenticatedRequest(
                requestID: requestID,
                idempotencyKey: idempotencyKey,
                channel: .development,
                installationID: fixture.manifest.installationID,
                command: .application(.start(start)),
                now: brokerTestDate
            )
            let decoded = try wire.decodeRequest(frame: wire.encode(request: signed))
            return endpoint.handle(
                decoded,
                peer: .init(effectiveUserID: 501, processID: 42),
                now: brokerTestDate
            )
        }

        let futureManifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            taskID: fixture.manifest.taskID,
            authority: fixture.manifest.authority,
            configuration: fixture.manifest.configuration,
            declaredEffects: fixture.manifest.declaredEffects,
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: brokerTestDate.addingTimeInterval(
                RunBrokerApplicationBounds.maximumLaunchFutureClockSkew + 1
            )
        )
        #expect(try response(
            manifest: futureManifest,
            requestID: brokerUUID(100),
            idempotencyKey: brokerUUID(101)
        ).error?.code == .applicationRequestRejected)

        let unknownEffectManifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            taskID: fixture.manifest.taskID,
            authority: fixture.manifest.authority,
            configuration: fixture.manifest.configuration,
            declaredEffects: [.init(scope: .unknown, access: .exclusive)],
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: fixture.manifest.createdAt
        )
        #expect(try response(
            manifest: unknownEffectManifest,
            requestID: brokerUUID(102),
            idempotencyKey: brokerUUID(103)
        ).error?.code == .applicationRequestRejected)

        let submillisecondManifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            taskID: fixture.manifest.taskID,
            authority: fixture.manifest.authority,
            configuration: fixture.manifest.configuration,
            declaredEffects: fixture.manifest.declaredEffects,
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: brokerTestDate.addingTimeInterval(0.000_5)
        )
        #expect(try response(
            manifest: submillisecondManifest,
            requestID: brokerUUID(112),
            idempotencyKey: brokerUUID(113)
        ).error?.code == .applicationRequestRejected)

        #expect(try fixture.ledger.events(limit: 100).isEmpty)
        #expect(fixture.vault.persistCount == 0)
        #expect(fixture.spawner.payloads.isEmpty)
    }

    @Test("Conflicting admission is denied by the pure ledger preflight before vault persistence")
    func effectConflictPreflightPrecedesCapabilityPersistence() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = applicationService(fixture)
        let exclusiveEffect = ExecutionEffectClaim(
            scope: .workspaceRepository(workspaceID: "workspace-1", repositoryID: nil),
            access: .exclusive
        )
        let firstManifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            taskID: fixture.manifest.taskID,
            authority: fixture.manifest.authority,
            configuration: fixture.manifest.configuration,
            declaredEffects: [exclusiveEffect],
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: fixture.manifest.createdAt
        )
        _ = try service.handle(
            .start(.init(
                taskRunID: firstManifest.executionID.rawValue,
                draft: applicationDraft(from: firstManifest),
                primaryOperationID: fixture.request().primaryOperationID,
                arguments: [],
                environment: [:]
            )),
            idempotencyKey: brokerUUID(104),
            now: brokerTestDate
        )

        let secondExecutionID = RunBrokerExecutionID(rawValue: brokerUUID(105))
        let conflictingManifest = ExecutionLaunchManifest(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: secondExecutionID,
            taskID: brokerUUID(106),
            authority: .init(id: .init(rawValue: brokerUUID(107)), epoch: .initial),
            configuration: fixture.manifest.configuration,
            declaredEffects: [exclusiveEffect],
            supervisionPolicy: fixture.manifest.supervisionPolicy,
            createdAt: fixture.manifest.createdAt
        )
        do {
            _ = try service.handle(
                .start(.init(
                    taskRunID: conflictingManifest.executionID.rawValue,
                    draft: applicationDraft(from: conflictingManifest),
                    primaryOperationID: .init(rawValue: brokerUUID(108)),
                    arguments: [],
                    environment: [:]
                )),
                idempotencyKey: brokerUUID(109),
                now: brokerTestDate
            )
            Issue.record("Expected effect-conflict admission denial")
        } catch let error as RunLedgerError {
            guard case .admissionDenied(let denials) = error else {
                Issue.record("Expected admission denial, received \(error)")
                return
            }
            #expect(denials.contains { denial in
                if case .effectConflict = denial { return true }
                return false
            })
        }

        #expect(fixture.vault.persistCount == 1)
        #expect(try fixture.vault.load(executionID: secondExecutionID) == nil)
        #expect(fixture.spawner.payloads.count == 1)
        #expect(try fixture.ledger.projection().executions[secondExecutionID] == nil)
    }

    @Test("start resumes only proven pre-spawn admission and reconciles post-spawn replay")
    func startCrashWindows() throws {
        let beforeSpawn = try BrokerFixture()
        #expect(throws: InjectedStartCrash.self) {
            _ = try beforeSpawn.orchestrator(
                fault: PointFaultInjector(point: .afterLedgerAdmission)
            ).start(beforeSpawn.request())
        }
        #expect(beforeSpawn.spawner.payloads.isEmpty)
        let resumed = try beforeSpawn.orchestrator().start(beforeSpawn.request())
        #expect(resumed.state == .admitted)
        #expect(beforeSpawn.spawner.payloads.count == 1)
        #expect(beforeSpawn.vault.persistCount == 1)

        let afterSpawn = try BrokerFixture()
        afterSpawn.transport.events = [
            afterSpawn.event(1, .supervisorReady),
            afterSpawn.event(2, .providerStarted),
        ]
        #expect(throws: InjectedStartCrash.self) {
            _ = try afterSpawn.orchestrator(
                fault: PointFaultInjector(point: .afterSupervisorSpawn)
            ).start(afterSpawn.request())
        }
        #expect(afterSpawn.spawner.payloads.count == 1)
        let reconciled = try afterSpawn.orchestrator().start(afterSpawn.request())
        #expect(reconciled.state == .running)
        #expect(afterSpawn.spawner.payloads.count == 1)
        #expect(afterSpawn.vault.persistCount == 1)
    }

    @Test("projection pull replays after restart and wrong acknowledgement fails closed")
    func projectionExactAcknowledgement() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let first = applicationService(fixture)
        let response = try first.handle(
            .nextProjectionMessage,
            idempotencyKey: brokerUUID(83),
            now: brokerTestDate
        )
        guard case .projectionMessage(let message?) = response else {
            Issue.record("Expected projection message")
            return
        }
        let restarted = applicationService(fixture)
        #expect(try restarted.handle(
            .nextProjectionMessage,
            idempotencyKey: brokerUUID(84),
            now: brokerTestDate
        ) == response)
        #expect(throws: RunBrokerApplicationEndpointError.projectionAcknowledgementConflict) {
            _ = try restarted.handle(
                .acknowledgeProjection(.init(
                    sequence: message.sequence,
                    messageID: brokerUUID(98)
                )),
                idempotencyKey: brokerUUID(85),
                now: brokerTestDate
            )
        }
        #expect(try fixture.ledger.outbox().first?.isAcknowledged == false)
        #expect(try restarted.handle(
            .acknowledgeProjection(.init(
                sequence: message.sequence,
                messageID: message.messageID
            )),
            idempotencyKey: brokerUUID(86),
            now: brokerTestDate
        ) == .projectionAcknowledged)
    }

    @Test("projection acknowledgement preserves ledger health failures")
    func projectionAcknowledgementDoesNotCollapseHealthErrors() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let service = applicationService(fixture)
        guard case .projectionMessage(let message?) = try service.handle(
            .nextProjectionMessage,
            idempotencyKey: brokerUUID(116),
            now: brokerTestDate
        ) else {
            Issue.record("Expected projection message")
            return
        }
        try fixture.ledger.close()

        #expect(throws: RunLedgerError.closed) {
            _ = try service.handle(
                .acknowledgeProjection(.init(
                    sequence: message.sequence,
                    messageID: message.messageID
                )),
                idempotencyKey: brokerUUID(117),
                now: brokerTestDate
            )
        }
    }

    @Test("only exact local supervisor immediate control performs an audited effect")
    func externalOperationControlMatrix() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = applicationService(fixture)
        _ = try service.handle(
            .start(.init(
                taskRunID: fixture.manifest.executionID.rawValue,
                draft: applicationDraft(from: fixture.manifest),
                primaryOperationID: fixture.request().primaryOperationID,
                arguments: [],
                environment: [:]
            )),
            idempotencyKey: brokerUUID(87),
            now: brokerTestDate
        )
        let authority = try currentAuthority(fixture)

        let supervisor = try ExternalOperationSupervisorIdentity(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            authority: authority
        )
        let backend = ExternalOperationBackendIdentity(supervisorIdentity: supervisor)
        let localBinding = ExternalOperationControlBinding(
            executionID: fixture.manifest.executionID,
            authority: authority,
            backendIdentity: backend,
            declaredCapabilities: [.observe, .immediateTermination]
        )
        let localTarget = ExternalOperationControlTarget(
            executionID: fixture.manifest.executionID,
            authority: authority,
            backendIdentity: backend
        )
        let immediate = RunBrokerApplicationExternalOperationRequest(
            target: localTarget,
            binding: localBinding,
            cancellationIntent: .immediate
        )
        #expect(throws: RunBrokerApplicationEndpointError.externalOperationBlocked) {
            _ = try service.handle(
                .externalOperation(.control(immediate)),
                idempotencyKey: brokerUUID(88),
                now: brokerTestDate.addingTimeInterval(3)
            )
        }
        #expect(fixture.transport.immediateTerminationCount == 0)

        guard case .externalOperation(let observed) = try service.handle(
            .externalOperation(.observe(immediate)),
            idempotencyKey: brokerUUID(96),
            now: brokerTestDate
        ) else {
            Issue.record("Expected verified local observation assessment")
            return
        }
        #expect(observed.observation.kind == .allowed)
        #expect(observed.observation.reason == .observationCapabilityVerified)

        let spoofedSupervisor = try ExternalOperationSupervisorIdentity(
            installationID: fixture.manifest.installationID,
            storeID: .init(rawValue: brokerUUID(114)),
            executionID: fixture.manifest.executionID,
            authority: authority
        )
        let spoofedBackend = ExternalOperationBackendIdentity(
            supervisorIdentity: spoofedSupervisor
        )
        let spoofedObservation = RunBrokerApplicationExternalOperationRequest(
            target: .init(
                executionID: fixture.manifest.executionID,
                authority: authority,
                backendIdentity: spoofedBackend
            ),
            binding: .init(
                executionID: fixture.manifest.executionID,
                authority: authority,
                backendIdentity: spoofedBackend,
                declaredCapabilities: [.observe, .immediateTermination]
            ),
            cancellationIntent: .none
        )
        #expect(throws: RunBrokerExternalOperationVerificationError.descriptorMismatch) {
            _ = try service.handle(
                .externalOperation(.observe(spoofedObservation)),
                idempotencyKey: brokerUUID(115),
                now: brokerTestDate
            )
        }
        #expect(fixture.transport.immediateTerminationCount == 0)

        // A later retry remains non-authoritative: this legacy command has no
        // durable actor/session challenge confirmation.
        #expect(throws: RunBrokerApplicationEndpointError.externalOperationBlocked) {
            _ = try service.handle(
                .externalOperation(.control(immediate)),
                idempotencyKey: brokerUUID(88),
                now: brokerTestDate.addingTimeInterval(30)
            )
        }
        #expect(fixture.transport.immediateTerminationCount == 0)

        let graceful = RunBrokerApplicationExternalOperationRequest(
            target: localTarget,
            binding: localBinding,
            cancellationIntent: .graceful
        )
        guard case .externalOperation(let gracefulAssessment) = try service.handle(
            .externalOperation(.control(graceful)),
            idempotencyKey: brokerUUID(89),
            now: brokerTestDate
        ) else {
            Issue.record("Expected graceful assessment")
            return
        }
        #expect(gracefulAssessment.cancellation.kind == .blocked)
        #expect(gracefulAssessment.cancellation.reason == .gracefulCancellationCapabilityMissing)
        #expect(fixture.transport.immediateTerminationCount == 0)

        for (index, kind) in [
            ExternalOperationBackendKindID.managedDockerJob,
            .sshRemoteOperation,
            .importedOperation,
            .opaqueOperation,
        ].enumerated() {
            let monitoringBackend = try ExternalOperationBackendIdentity(
                monitoringKind: kind,
                instanceID: "operation-\(index)"
            )
            let request = RunBrokerApplicationExternalOperationRequest(
                target: .init(
                    executionID: fixture.manifest.executionID,
                    authority: authority,
                    backendIdentity: monitoringBackend
                ),
                binding: .init(
                    executionID: fixture.manifest.executionID,
                    authority: authority,
                    backendIdentity: monitoringBackend,
                    declaredCapabilities: .monitoringOnly
                ),
                cancellationIntent: .immediate
            )
            guard case .externalOperation(let assessment) = try service.handle(
                .externalOperation(.control(request)),
                idempotencyKey: brokerUUID(UInt8(90 + index)),
                now: brokerTestDate
            ) else {
                Issue.record("Expected monitoring-only assessment")
                continue
            }
            #expect(assessment.observation.kind == .blocked)
            #expect(assessment.observation.reason == .unverifiedProvenance)
            #expect(assessment.cancellation.kind == .monitoringOnly)
        }
        #expect(fixture.transport.immediateTerminationCount == 0)
    }

    @Test("direct immediate confirmation uses distinct durable IDs and replays after challenge issuance")
    func directImmediateConfirmationIsEndToEndAndReplaySafe() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(120)
        )
        let effectID = RuntimeSwitchEffectID(rawValue: brokerUUID(121))
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: effectID
        )
        fixture.transport.onImmediateTermination = {
            fixture.transport.events.append(
                fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
            )
        }

        guard case .executionControl(let accepted) = try service.handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(122),
            now: brokerTestDate.addingTimeInterval(4)
        ) else {
            Issue.record("Expected immediate-control acceptance")
            return
        }
        #expect(accepted.cancellationIntent == .immediate)
        #expect(accepted.acceptedEffectID == effectID)
        #expect(fixture.transport.immediateTerminationCount == 1)

        let challengeID = challenge.challengeID.rawValue
        let consumptionID = RunBrokerExecutionForceEventIDs.consumption(effectID: effectID)
        let auditID = RunBrokerExecutionForceEventIDs.audit(effectID: effectID)
        #expect(Set([challengeID, consumptionID, auditID]).count == 3)
        #expect(challengeID != brokerUUID(120))
        let events = try fixture.ledger.events(limit: 100)
        #expect(events.contains { $0.envelope.eventID.rawValue == challengeID })
        #expect(events.contains { $0.envelope.eventID.rawValue == consumptionID })
        #expect(events.contains { $0.envelope.eventID.rawValue == auditID })

        let restarted = applicationService(fixture)
        _ = try restarted.handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(123),
            now: brokerTestDate.addingTimeInterval(30)
        )
        #expect(fixture.transport.immediateTerminationCount == 1)
    }

    @Test("confirmation resumes after consumption committed but before cancellation audit")
    func immediateConfirmationResumesAfterConsumption() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(124)
        )
        let effectID = RuntimeSwitchEffectID(rawValue: brokerUUID(125))
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: effectID
        )
        try recordConsumption(fixture, confirmation: confirmation)
        fixture.transport.onImmediateTermination = {
            fixture.transport.events.append(
                fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
            )
        }

        _ = try applicationService(fixture).handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(126),
            now: brokerTestDate.addingTimeInterval(5)
        )

        #expect(fixture.transport.immediateTerminationCount == 1)
        #expect(try fixture.ledger.event(eventID: .init(
            rawValue: RunBrokerExecutionForceEventIDs.audit(effectID: effectID)
        )) != nil)
    }

    @Test("server receipt rejects a first confirmation after expiry but preserves consumed replay")
    func immediateConfirmationUsesServerExpiryForFirstConsumption() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(143)
        )
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: .init(rawValue: brokerUUID(144))
        )
        let afterExpiry = challenge.expiresAt.addingTimeInterval(1)

        #expect(throws: RunBrokerApplicationEndpointError.requestRejected) {
            _ = try service.handle(
                .confirmImmediateCancellation(confirmation),
                idempotencyKey: brokerUUID(145),
                now: afterExpiry
            )
        }
        #expect(try fixture.ledger.projection().executionForceConsumptions.isEmpty)
        #expect(fixture.transport.immediateTerminationCount == 0)

        // Model a response-lost confirmation that was durably consumed while
        // the challenge was live. Its exact replay remains resumable later.
        try recordConsumption(fixture, confirmation: confirmation)
        fixture.transport.onImmediateTermination = {
            fixture.transport.events.append(
                fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
            )
        }
        _ = try applicationService(fixture).handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(146),
            now: afterExpiry.addingTimeInterval(60)
        )
        #expect(fixture.transport.immediateTerminationCount == 1)
    }

    @Test("broker reconciliation resumes consumed confirmation without an app replay")
    func brokerRecoveryResumesConsumedUnauditedCancellation() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(147)
        )
        let effectID = RuntimeSwitchEffectID(rawValue: brokerUUID(148))
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: effectID
        )
        try recordConsumption(fixture, confirmation: confirmation)
        fixture.transport.onImmediateTermination = {
            fixture.transport.events.append(
                fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
            )
        }
        let broker = fixture.orchestrator(
            authorizer: AllowExactRunBrokerImmediateTerminationAuthorizer()
        )

        _ = try broker.reconcile(executionID: fixture.manifest.executionID)

        let auditID = RunBrokerExecutionForceEventIDs.audit(effectID: effectID)
        #expect(try fixture.ledger.event(eventID: .init(rawValue: auditID)) != nil)
        #expect(fixture.transport.immediateTerminationCount == 1)
        #expect(try fixture.ledger.supervisorObservations(
            for: fixture.manifest.executionID
        ).contains {
            $0.kind == .cancellationRequested
                && $0.cancellationIntent == .immediate
        })

        _ = try broker.reconcile(executionID: fixture.manifest.executionID)
        #expect(fixture.transport.immediateTerminationCount == 1)
    }

    @Test("consumed confirmation cannot terminate a later execution authority")
    func consumedConfirmationRejectsAuthorityTransfer() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(138)
        )
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: .init(rawValue: brokerUUID(139))
        )
        try recordConsumption(fixture, confirmation: confirmation)
        let authority = try currentAuthority(fixture)
        _ = try fixture.ledger.append(.init(
            eventID: .init(rawValue: brokerUUID(140)),
            occurredAt: brokerTestDate.addingTimeInterval(5),
            event: .executionAuthorityTransferred(
                executionID: fixture.manifest.executionID,
                expectedAuthority: authority,
                newAuthority: .init(
                    id: .init(rawValue: brokerUUID(141)),
                    epoch: .init(rawValue: 2)
                )
            )
        ))

        #expect(throws: RunBrokerApplicationEndpointError.requestRejected) {
            _ = try applicationService(fixture).handle(
                .confirmImmediateCancellation(confirmation),
                idempotencyKey: brokerUUID(142),
                now: brokerTestDate.addingTimeInterval(6)
            )
        }
        #expect(fixture.transport.immediateTerminationCount == 0)
    }

    @Test("confirmation resumes after audit committed but before supervisor effect")
    func immediateConfirmationResumesAfterAudit() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(127)
        )
        let effectID = RuntimeSwitchEffectID(rawValue: brokerUUID(128))
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: effectID
        )
        try recordConsumption(fixture, confirmation: confirmation)
        try recordCancellationAudit(fixture, confirmation: confirmation)
        fixture.transport.onImmediateTermination = {
            fixture.transport.events.append(
                fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
            )
        }

        _ = try applicationService(fixture).handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(129),
            now: brokerTestDate.addingTimeInterval(6)
        )

        #expect(fixture.transport.immediateTerminationCount == 1)
        let auditID = RunBrokerExecutionForceEventIDs.audit(effectID: effectID)
        #expect(try fixture.ledger.events(limit: 100).filter {
            $0.envelope.eventID.rawValue == auditID
        }.count == 1)
    }

    @Test("durable supervisor evidence prevents reissuing after response loss")
    func immediateConfirmationReconcilesDurableEffectEvidence() throws {
        let fixture = try BrokerFixture()
        let service = try authenticatedControlService(fixture)
        let (request, challenge) = try issueImmediateChallenge(
            fixture: fixture,
            service: service,
            idempotencyKey: brokerUUID(130)
        )
        let effectID = RuntimeSwitchEffectID(rawValue: brokerUUID(131))
        let confirmation = immediateConfirmation(
            request: request,
            challenge: challenge,
            effectID: effectID
        )
        try recordConsumption(fixture, confirmation: confirmation)
        try recordCancellationAudit(fixture, confirmation: confirmation)
        fixture.transport.events.append(
            fixture.event(3, .cancellationRequested, cancellationIntent: .immediate)
        )
        _ = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )

        _ = try applicationService(fixture).handle(
            .confirmImmediateCancellation(confirmation),
            idempotencyKey: brokerUUID(132),
            now: brokerTestDate.addingTimeInterval(7)
        )

        #expect(fixture.transport.immediateTerminationCount == 0)
        // cancellationRequested is durable supervisor acceptance evidence for
        // replay suppression. The control projection intentionally remains
        // requestPending until terminationStarted or cancellationConfirmed.
        #expect(try fixture.ledger.projection().executions[
            fixture.manifest.executionID
        ]?.control.observedCancellation == .requestPending)
        #expect(try fixture.ledger.events(limit: 100).contains {
            guard case .supervisorObservationRecorded(let observation) = $0.envelope.event else {
                return false
            }
            return observation.executionID == fixture.manifest.executionID
                && observation.supervisorSequence == 3
                && observation.kind == .cancellationRequested
                && observation.cancellationIntent == .immediate
        })
    }

    @Test("a stale vault record remains unverified and cannot mint a challenge")
    func staleVaultRecordIsMonitoringOnly() throws {
        let fixture = try BrokerFixture()
        #expect(throws: InjectedStartCrash.self) {
            _ = try fixture.orchestrator(
                fault: PointFaultInjector(point: .afterCapabilitySync)
            ).start(fixture.request())
        }
        let service = applicationService(fixture)
        let external = try localExternalOperation(fixture, intent: .immediate)

        guard case .externalOperation(let assessment) = try service.handle(
            .externalOperation(.observe(external)),
            idempotencyKey: brokerUUID(133),
            now: brokerTestDate.addingTimeInterval(2)
        ) else {
            Issue.record("Expected unverified descriptor assessment")
            return
        }
        #expect(assessment.observation.kind == .blocked)
        #expect(assessment.observation.reason == .unverifiedProvenance)
        #expect(assessment.cancellation.kind != .allowed)

        let request = try immediateCancellationRequest(fixture, expectedSequence: 0)
        #expect(throws: RunBrokerServiceError.supervisorUnavailable) {
            _ = try service.handle(
                .requestImmediateCancellationChallenge(request),
                idempotencyKey: brokerUUID(134),
                now: brokerTestDate.addingTimeInterval(2)
            )
        }
        #expect(try fixture.ledger.projection().executionForceChallenges.isEmpty)
        #expect(fixture.transport.immediateTerminationCount == 0)
    }

    private func applicationService(_ fixture: BrokerFixture) -> RunBrokerApplicationService {
        let orchestrator = RunBrokerOrchestrator(
            ledger: fixture.ledger,
            vault: fixture.vault,
            spawner: fixture.spawner,
            transport: fixture.transport,
            installedBrokerExecutableURL: fixture.root.appendingPathComponent("installed/astra-run-broker"),
            allowAuthenticatedImmediateTermination: true,
            logger: fixture.logger
        )
        return .init(ledger: fixture.ledger, orchestrator: orchestrator, vault: fixture.vault)
    }

    private func authenticatedControlService(
        _ fixture: BrokerFixture
    ) throws -> RunBrokerApplicationService {
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = applicationService(fixture)
        _ = try service.handle(
            .start(.init(
                taskRunID: fixture.manifest.executionID.rawValue,
                draft: applicationDraft(from: fixture.manifest),
                primaryOperationID: fixture.request().primaryOperationID,
                arguments: [],
                environment: [:]
            )),
            idempotencyKey: brokerUUID(118),
            now: brokerTestDate
        )
        return service
    }

    private func immediateCancellationRequest(
        _ fixture: BrokerFixture,
        expectedSequence: UInt64 = 2
    ) throws -> RunBrokerApplicationImmediateCancellationRequest {
        let authority = try currentAuthority(fixture)
        return .init(
            requestID: brokerUUID(119),
            fence: .init(
                executionID: fixture.manifest.executionID,
                authority: authority,
                expectedSupervisorSequence: expectedSequence
            ),
            actorID: try .init(rawValue: "operator-1"),
            sessionID: brokerUUID(119),
            audit: .init(
                auditID: .init(rawValue: brokerUUID(119)),
                source: .diagnostics,
                reasonCode: .operatorEmergencyStop
            )
        )
    }

    private func issueImmediateChallenge(
        fixture: BrokerFixture,
        service: RunBrokerApplicationService,
        idempotencyKey: UUID
    ) throws -> (
        RunBrokerApplicationImmediateCancellationRequest,
        ExecutionForceChallenge
    ) {
        let request = try immediateCancellationRequest(fixture)
        guard case .executionControl(let status) = try service.handle(
            .requestImmediateCancellationChallenge(request),
            idempotencyKey: idempotencyKey,
            now: brokerTestDate.addingTimeInterval(3)
        ), let challenge = status.challenge else {
            throw RunBrokerApplicationContractError.unexpectedApplicationResponse
        }
        return (request, challenge)
    }

    private func immediateConfirmation(
        request: RunBrokerApplicationImmediateCancellationRequest,
        challenge: ExecutionForceChallenge,
        effectID: RuntimeSwitchEffectID
    ) -> RunBrokerApplicationImmediateCancellationConfirmation {
        .init(
            fence: request.fence,
            challengeID: challenge.challengeID,
            requestDigest: challenge.requestDigest,
            actorID: request.actorID,
            sessionID: request.sessionID,
            confirmedAt: brokerTestDate.addingTimeInterval(4),
            effectID: effectID
        )
    }

    private func recordConsumption(
        _ fixture: BrokerFixture,
        confirmation: RunBrokerApplicationImmediateCancellationConfirmation
    ) throws {
        _ = try fixture.ledger.consumeExecutionForceChallenge(
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
    }

    private func recordCancellationAudit(
        _ fixture: BrokerFixture,
        confirmation: RunBrokerApplicationImmediateCancellationConfirmation
    ) throws {
        _ = try fixture.ledger.append(.init(
            eventID: .init(rawValue: RunBrokerExecutionForceEventIDs.audit(
                effectID: confirmation.effectID
            )),
            occurredAt: confirmation.confirmedAt,
            event: .executionControlTransitioned(
                executionID: confirmation.fence.executionID,
                authority: confirmation.fence.authority,
                transition: .requestCancellation(.immediate),
                backendCapabilities: [.observe, .cancel]
            )
        ))
    }

    private func localExternalOperation(
        _ fixture: BrokerFixture,
        intent: ExecutionCancellationIntent
    ) throws -> RunBrokerApplicationExternalOperationRequest {
        let authority = try currentAuthority(fixture)
        let supervisor = try ExternalOperationSupervisorIdentity(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            authority: authority
        )
        let backend = ExternalOperationBackendIdentity(supervisorIdentity: supervisor)
        return .init(
            target: .init(
                executionID: fixture.manifest.executionID,
                authority: authority,
                backendIdentity: backend
            ),
            binding: .init(
                executionID: fixture.manifest.executionID,
                authority: authority,
                backendIdentity: backend,
                declaredCapabilities: [.observe, .immediateTermination]
            ),
            cancellationIntent: intent
        )
    }

    private func currentAuthority(_ fixture: BrokerFixture) throws -> RunBrokerAuthority {
        try #require(
            fixture.ledger.projection().executions[fixture.manifest.executionID]?.authority
        )
    }
}

private func runtimeSwitchSubmission(
    fixture: BrokerFixture,
    requestID: RuntimeSwitchRequestID,
    targetExecutionID: RunBrokerExecutionID,
    requestedAt: Date
) throws -> RunBrokerApplicationRuntimeSwitchSubmission {
    let source = try RuntimeSwitchSourceFence(
        manifest: fixture.manifest,
        manifestSHA256: RuntimeSwitchDigests.manifest(fixture.manifest)
    )
    let target = RunBrokerApplicationLaunchDraft(
        executionID: targetExecutionID,
        taskID: fixture.manifest.taskID,
        configuration: .init(
            runtimeID: .claudeCode,
            executablePath: "/usr/bin/true",
            workingDirectory: "/tmp",
            configurationRevision: "runtime-switch-time-test"
        ),
        declaredEffects: fixture.manifest.declaredEffects,
        supervisionPolicy: try #require(fixture.manifest.supervisionPolicy),
        createdAt: brokerTestDate
    )
    return .init(
        requestID: requestID,
        mode: .immediate,
        expectedSource: source,
        targetDraft: target,
        requestedAt: requestedAt,
        forceAudit: .init(
            auditID: .init(rawValue: requestID.rawValue),
            source: .diagnostics,
            reasonCode: .operatorEmergencyStop
        ),
        targetProtocol: .baseline,
        actorID: try .init(rawValue: "operator-time-test"),
        sessionID: requestID.rawValue
    )
}

private struct ImmediateAdmissionOnlyRuntimeSwitchBackend: RunBrokerRuntimeSwitchBackend {
    let supportsGracefulHandoff = false
    let supportsImmediateTermination = true

    func safeCheckpoint(for: RuntimeSwitchRecord) throws -> RunBrokerCheckpointEvidence? { nil }
    func handoffIf(_: RuntimeSwitchControlDirective) throws {}
    func controlAcceptance(for: RuntimeSwitchRecord) throws -> RunBrokerControlAcceptanceEvidence? { nil }
    func terminalEvidence(for: RuntimeSwitchRecord) throws -> RunBrokerTerminalEvidence? { nil }
    func startReservedIf(
        reservation: RuntimeSwitchTargetReservation,
        manifestDigest: ExecutionLaunchArgumentsSHA256,
        effectID: RuntimeSwitchEffectID,
        directive: RuntimeSwitchReplacementDirective
    ) throws -> RunBrokerReplacementAcceptanceEvidence? { nil }
    func replacementRunning(for: RuntimeSwitchRecord) throws -> RunBrokerReplacementRunningEvidence? { nil }
}

private final class BrokerWireSequenceRandom: RunBrokerRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var byte: UInt8 = 0

    func randomBytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        byte &+= 1
        return Data(repeating: byte, count: count)
    }
}
