import Foundation
import Testing
import ASTRACore

@Suite("RunBroker identity, manifest, and runtime intent contracts")
struct RunBrokerIdentityAndManifestTests {
    @Test("Launch manifest round-trips immutable typed identities and secret-free configuration")
    func manifestRoundTrip() throws {
        let sensitiveArgument = "--token=do-not-persist-this-secret"
        let argumentDigest = try ExecutionLaunchArgumentsSHA256(
            hexValue: String(repeating: "A", count: 64)
        )
        let argumentSummary = try ExecutionLaunchArgumentSummary(
            redactedArgumentCount: 2,
            argumentsSHA256: argumentDigest
        )
        let manifest = ExecutionLaunchManifest(
            installationID: installationID(1),
            storeID: storeID(2),
            executionID: executionID(3),
            taskID: fixedUUID(4),
            authority: authority(5, epoch: 7),
            configuration: .init(
                runtimeID: .codexCLI,
                modelID: "  gpt-test  ",
                executablePath: "/usr/local/bin/codex",
                launchArguments: argumentSummary,
                workingDirectory: "/workspace/repo",
                environmentVariableNames: ["PATH", "TOKEN_REF", "PATH"],
                configurationRevision: "sha256:launch-config"
            ),
            declaredEffects: [
                .init(
                    scope: .workspaceRepository(workspaceID: "workspace-1", repositoryID: "repo-1"),
                    access: .exclusive
                )
            ],
            createdAt: fixedDate
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ExecutionLaunchManifest.self, from: encoded)
        let encodedText = String(decoding: encoded, as: UTF8.self)

        #expect(decoded == manifest)
        #expect(!encodedText.contains(sensitiveArgument))
        #expect(decoded.configuration.launchArguments.argumentCount == 2)
        #expect(decoded.configuration.launchArguments.argumentsSHA256 == argumentDigest)
        #expect(decoded.configuration.modelID == "gpt-test")
        #expect(decoded.configuration.environmentVariableNames == ["PATH", "TOKEN_REF"])
        #expect(ActiveExecutionRuntime(manifest: decoded).runtimeID == .codexCLI)
    }

    @Test("Unsupported launch manifest schema fails closed")
    func unsupportedManifestSchemaIsRejected() throws {
        let manifest = ExecutionLaunchManifest(
            installationID: installationID(6),
            storeID: storeID(7),
            executionID: executionID(8),
            taskID: fixedUUID(9),
            authority: authority(10, epoch: 1),
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/local/bin/codex",
                workingDirectory: "/workspace/repo",
                configurationRevision: "sha256:launch-config"
            ),
            declaredEffects: [.computeOnly],
            createdAt: fixedDate
        )
        let encoded = try JSONEncoder().encode(manifest)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = ExecutionLaunchManifest.currentSchemaVersion + 1
        let unsupported = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExecutionLaunchManifest.self, from: unsupported)
        }
    }

    @Test("Runtime selection changes next intent without rewriting active runtime")
    func activeRuntimeIsIndependentFromNextRuntime() {
        let active = ActiveExecutionRuntime(executionID: executionID(10), runtimeID: .claudeCode)
        let initial = ExecutionRuntimeIntentState(active: active, nextRuntimeID: .claudeCode)

        let selected = ExecutionRuntimeIntentReducer.reduce(
            initial,
            event: .selectNextRuntime(.copilotCLI)
        )

        #expect(selected.disposition == .applied)
        #expect(selected.state.active == active)
        #expect(selected.state.nextRuntimeID == .copilotCLI)

        let staleFinish = ExecutionRuntimeIntentReducer.reduce(
            selected.state,
            event: .executionFinished(executionID(11))
        )
        #expect(staleFinish.disposition == .staleExecutionIgnored)
        #expect(staleFinish.state == selected.state)

        let finished = ExecutionRuntimeIntentReducer.reduce(
            selected.state,
            event: .executionFinished(active.executionID)
        )
        #expect(finished.disposition == .applied)
        #expect(finished.state.active == nil)
        #expect(finished.state.nextRuntimeID == .copilotCLI)
    }

    @Test("A second active execution is rejected while replay is idempotent")
    func activeExecutionStartIsExclusive() {
        let first = ActiveExecutionRuntime(executionID: executionID(12), runtimeID: .codexCLI)
        let second = ActiveExecutionRuntime(executionID: executionID(13), runtimeID: .cursorCLI)
        let initial = ExecutionRuntimeIntentState(nextRuntimeID: .codexCLI)
        let started = ExecutionRuntimeIntentReducer.reduce(initial, event: .executionStarted(first))

        #expect(ExecutionRuntimeIntentReducer.reduce(
            started.state,
            event: .executionStarted(first)
        ).disposition == .idempotent)
        #expect(ExecutionRuntimeIntentReducer.reduce(
            started.state,
            event: .executionStarted(second)
        ).disposition == .rejectedActiveExecution)
    }
}

@Suite("Execution effect scope overlap")
struct ExecutionEffectScopeTests {
    @Test("Workspace-wide claims overlap repositories while sibling repositories do not")
    func workspaceRepositoryOverlap() {
        let workspace = ExecutionEffectScope.workspaceRepository(
            workspaceID: "workspace-a",
            repositoryID: nil
        )
        let repoA = ExecutionEffectScope.workspaceRepository(
            workspaceID: "workspace-a",
            repositoryID: "repo-a"
        )
        let repoB = ExecutionEffectScope.workspaceRepository(
            workspaceID: "workspace-a",
            repositoryID: "repo-b"
        )
        let otherWorkspace = ExecutionEffectScope.workspaceRepository(
            workspaceID: "workspace-b",
            repositoryID: "repo-a"
        )

        #expect(workspace.overlaps(repoA))
        #expect(repoA.overlaps(workspace))
        #expect(!repoA.overlaps(repoB))
        #expect(!repoA.overlaps(otherWorkspace))
    }

    @Test("Remote paths use host identity and component-aware ancestry")
    func remotePathOverlap() {
        let root = ExecutionEffectScope.remotePath(hostID: "cluster-a", path: "/srv/jobs/repo")
        let child = ExecutionEffectScope.remotePath(
            hostID: "cluster-a",
            path: "/srv/jobs/./repo/results"
        )
        let prefixOnly = ExecutionEffectScope.remotePath(
            hostID: "cluster-a",
            path: "/srv/jobs/repository"
        )
        let otherHost = ExecutionEffectScope.remotePath(
            hostID: "cluster-b",
            path: "/srv/jobs/repo/results"
        )

        #expect(root.overlaps(child))
        #expect(child.overlaps(root))
        #expect(!root.overlaps(prefixOnly))
        #expect(!root.overlaps(otherHost))
    }

    @Test("Database-wide claims overlap datasets while different datasets remain independent")
    func datasetDatabaseOverlap() {
        let database = ExecutionEffectScope.datasetDatabase(
            dataSourceID: "warehouse",
            databaseID: "pcornet",
            datasetID: nil
        )
        let q1 = ExecutionEffectScope.datasetDatabase(
            dataSourceID: "warehouse",
            databaseID: "pcornet",
            datasetID: "q1"
        )
        let q2 = ExecutionEffectScope.datasetDatabase(
            dataSourceID: "warehouse",
            databaseID: "pcornet",
            datasetID: "q2"
        )

        #expect(database.overlaps(q1))
        #expect(!q1.overlaps(q2))
    }

    @Test("Cloud resources match stable identity and compute-only never conflicts")
    func cloudAndComputeOverlap() {
        let bucket = ExecutionEffectScope.cloudResource(
            providerID: "aws",
            resourceID: "s3:reports"
        )
        let sameBucket = ExecutionEffectScope.cloudResource(
            providerID: "aws",
            resourceID: "s3:reports"
        )
        let otherBucket = ExecutionEffectScope.cloudResource(
            providerID: "aws",
            resourceID: "s3:archive"
        )

        #expect(bucket.overlaps(sameBucket))
        #expect(!bucket.overlaps(otherBucket))
        #expect(!ExecutionEffectScope.computeOnly.overlaps(bucket))
        #expect(!ExecutionEffectScope.unknown.overlaps(.computeOnly))
        #expect(ExecutionEffectScope.unknown.overlaps(bucket))
    }

    @Test("Exclusive access conflicts with overlapping readers; shared readers coexist")
    func accessConflict() {
        let scope = ExecutionEffectScope.cloudResource(providerID: "gcp", resourceID: "dataset-1")
        let reader = ExecutionEffectClaim(scope: scope, access: .shared)
        let writer = ExecutionEffectClaim(scope: scope, access: .exclusive)

        #expect(!reader.conflicts(with: reader))
        #expect(reader.conflicts(with: writer))
        #expect(writer.conflicts(with: reader))
    }
}

@Suite("Execution admission and durable claims")
struct ExecutionAdmissionAndClaimTests {
    @Test("Overlapping write-capable execution is denied while shared readers coexist")
    func overlappingWriterIsDenied() {
        let scope = ExecutionEffectScope.workspaceRepository(
            workspaceID: "workspace-a",
            repositoryID: "repo-a"
        )
        let existingReader = claimRecord(
            execution: 20,
            operation: 21,
            effects: [.init(scope: scope, access: .shared)]
        )
        let writer = admissionRequest(
            execution: 22,
            operation: 23,
            effects: [.init(scope: scope, access: .exclusive)]
        )
        let reader = admissionRequest(
            execution: 24,
            operation: 25,
            effects: [.init(scope: scope, access: .shared)]
        )

        #expect(hasEffectConflict(ExecutionAdmissionPolicy.decide(
            request: writer,
            existingRecords: [existingReader]
        )))
        #expect(ExecutionAdmissionPolicy.decide(
            request: reader,
            existingRecords: [existingReader]
        ) == .admitted)
    }

    @Test("Non-overlapping exclusive executions are admitted")
    func nonOverlappingWritersAreAdmitted() {
        let existing = claimRecord(
            execution: 30,
            operation: 31,
            effects: [.init(
                scope: .datasetDatabase(
                    dataSourceID: "warehouse",
                    databaseID: "pcornet",
                    datasetID: "q1"
                ),
                access: .exclusive
            )]
        )
        let request = admissionRequest(
            execution: 32,
            operation: 33,
            effects: [.init(
                scope: .datasetDatabase(
                    dataSourceID: "warehouse",
                    databaseID: "pcornet",
                    datasetID: "q2"
                ),
                access: .exclusive
            )]
        )

        #expect(ExecutionAdmissionPolicy.decide(
            request: request,
            existingRecords: [existing]
        ) == .admitted)
    }

    @Test("Undeclared and unknown effects fail closed; explicit compute-only is admitted")
    func unknownEffectsFailClosed() {
        let undeclared = admissionRequest(execution: 40, operation: 41, effects: [])
        let unknown = admissionRequest(
            execution: 42,
            operation: 43,
            effects: [.init(scope: .unknown, access: .exclusive)]
        )
        let compute = admissionRequest(
            execution: 44,
            operation: 45,
            effects: [.computeOnly]
        )

        #expect(hasDenial(.effectsUndeclared, in: ExecutionAdmissionPolicy.decide(
            request: undeclared,
            existingRecords: []
        )))
        #expect(hasUnknownEffectDenial(ExecutionAdmissionPolicy.decide(
            request: unknown,
            existingRecords: []
        )))
        #expect(ExecutionAdmissionPolicy.decide(
            request: compute,
            existingRecords: []
        ) == .admitted)
    }

    @Test("Active unknown effect blocks effectful successors but not compute-only work")
    func existingUnknownEffectBlocksConservatively() {
        let existing = claimRecord(
            execution: 50,
            operation: 51,
            effects: [.init(scope: .unknown, access: .shared)]
        )
        let writer = admissionRequest(
            execution: 52,
            operation: 53,
            effects: [.init(
                scope: .cloudResource(providerID: "aws", resourceID: "bucket"),
                access: .exclusive
            )]
        )
        let compute = admissionRequest(
            execution: 54,
            operation: 55,
            effects: [.computeOnly]
        )

        #expect(hasEffectConflict(ExecutionAdmissionPolicy.decide(
            request: writer,
            existingRecords: [existing]
        )))
        #expect(ExecutionAdmissionPolicy.decide(
            request: compute,
            existingRecords: [existing]
        ) == .admitted)
    }

    @Test("Tombstones release effects but permanently reject operation identity reuse")
    func tombstoneAdmissionSemantics() {
        let released = claimRecord(
            execution: 60,
            operation: 61,
            effects: [.init(
                scope: .cloudResource(providerID: "gcp", resourceID: "dataset"),
                access: .exclusive
            )],
            state: .tombstoned(.init(reason: .completed, recordedAt: fixedDate))
        )
        let newOperation = admissionRequest(
            execution: 62,
            operation: 63,
            effects: released.effects
        )
        let reusedOperation = admissionRequest(
            execution: 60,
            operation: 61,
            effects: released.effects
        )

        #expect(ExecutionAdmissionPolicy.decide(
            request: newOperation,
            existingRecords: [released]
        ) == .admitted)
        #expect(hasTombstoneDenial(ExecutionAdmissionPolicy.decide(
            request: reusedOperation,
            existingRecords: [released]
        )))
    }

    @Test("Operation identity cannot be rebound to another execution, store, or effect declaration")
    func operationIdentityIsImmutable() {
        let sharedAuthority = authority(66, epoch: 2)
        let originalEffect = ExecutionEffectClaim.computeOnly
        let existing = claimRecord(
            execution: 67,
            operation: 68,
            authority: sharedAuthority,
            effects: [originalEffect]
        )
        let differentExecution = admissionRequest(
            execution: 69,
            operation: 68,
            authority: sharedAuthority,
            effects: [originalEffect]
        )
        let changedEffects = admissionRequest(
            execution: 67,
            operation: 68,
            authority: sharedAuthority,
            effects: [.init(
                scope: .cloudResource(providerID: "aws", resourceID: "bucket"),
                access: .exclusive
            )]
        )
        let differentStore = ExecutionAdmissionRequest(
            storeID: storeID(901),
            operationID: existing.operationID,
            executionID: existing.executionID,
            authority: sharedAuthority,
            effects: [originalEffect]
        )

        #expect(hasOperationIdentityConflict(ExecutionAdmissionPolicy.decide(
            request: differentExecution,
            existingRecords: [existing]
        )))
        #expect(hasOperationIdentityConflict(ExecutionAdmissionPolicy.decide(
            request: changedEffects,
            existingRecords: [existing]
        )))
        #expect(hasOperationIdentityConflict(ExecutionAdmissionPolicy.decide(
            request: differentStore,
            existingRecords: [existing]
        )))
    }

    @Test("Duplicate durable records for one operation fail closed")
    func duplicateOperationRecordsAreDenied() {
        let existing = claimRecord(
            execution: 64,
            operation: 65,
            effects: [.computeOnly]
        )
        let replay = admissionRequest(
            execution: 64,
            operation: 65,
            effects: [.computeOnly]
        )

        #expect(hasDuplicateOperationDenial(ExecutionAdmissionPolicy.decide(
            request: replay,
            existingRecords: [existing, existing]
        )))
    }

    @Test("Stale epochs and same-epoch split authority are rejected")
    func staleEpochAdmissionIsRejected() {
        let existing = claimRecord(
            execution: 70,
            operation: 71,
            authority: authority(72, epoch: 4),
            effects: [.computeOnly]
        )
        let stale = admissionRequest(
            execution: 70,
            operation: 71,
            authority: authority(72, epoch: 3),
            effects: [.computeOnly]
        )
        let split = admissionRequest(
            execution: 70,
            operation: 71,
            authority: authority(73, epoch: 4),
            effects: [.computeOnly]
        )

        #expect(hasStaleEpochDenial(ExecutionAdmissionPolicy.decide(
            request: stale,
            existingRecords: [existing]
        )))
        #expect(hasAuthorityConflict(ExecutionAdmissionPolicy.decide(
            request: split,
            existingRecords: [existing]
        )))
    }

    @Test("Same fenced execution may hold overlapping operations and replay is idempotent")
    func sameExecutionClaimsAreCompatible() {
        let sharedAuthority = authority(80, epoch: 2)
        let effect = ExecutionEffectClaim(
            scope: .remotePath(hostID: "remote", path: "/data/export"),
            access: .exclusive
        )
        let existing = claimRecord(
            execution: 81,
            operation: 82,
            authority: sharedAuthority,
            effects: [effect]
        )
        let additional = admissionRequest(
            execution: 81,
            operation: 83,
            authority: sharedAuthority,
            effects: [effect]
        )
        let replay = admissionRequest(
            execution: 81,
            operation: 82,
            authority: sharedAuthority,
            effects: [effect]
        )

        #expect(ExecutionAdmissionPolicy.decide(
            request: additional,
            existingRecords: [existing]
        ) == .admitted)
        #expect(ExecutionAdmissionPolicy.decide(
            request: replay,
            existingRecords: [existing]
        ) == .alreadyAdmitted)
    }

    @Test("Claim reducer fences stale owners and makes tombstones absorbing")
    func durableClaimReducerFencesAndTombstones() {
        let initial = claimRecord(
            execution: 90,
            operation: 91,
            authority: authority(92, epoch: 2),
            effects: [.computeOnly]
        )
        let stale = DurableExecutionClaimReducer.reduce(
            initial,
            event: .transferAuthority(authority(93, epoch: 1), at: fixedDate.addingTimeInterval(1))
        )
        #expect(stale.disposition == .staleEpochRejected)
        #expect(stale.record == initial)

        let transferred = DurableExecutionClaimReducer.reduce(
            initial,
            event: .transferAuthority(authority(93, epoch: 3), at: fixedDate.addingTimeInterval(2))
        )
        #expect(transferred.disposition == .applied)
        #expect(transferred.record.authority == authority(93, epoch: 3))

        let tombstoneEvent = DurableExecutionClaimEvent.tombstone(
            authority: authority(93, epoch: 3),
            reason: .completed,
            at: fixedDate.addingTimeInterval(3)
        )
        let tombstoned = DurableExecutionClaimReducer.reduce(transferred.record, event: tombstoneEvent)
        #expect(tombstoned.disposition == .applied)
        #expect(!tombstoned.record.holdsEffects)
        #expect(DurableExecutionClaimReducer.reduce(
            tombstoned.record,
            event: tombstoneEvent
        ).disposition == .idempotent)
        #expect(DurableExecutionClaimReducer.reduce(
            tombstoned.record,
            event: .transferAuthority(authority(94, epoch: 4), at: fixedDate.addingTimeInterval(4))
        ).disposition == .tombstoneIsFinal)
    }
}

@Suite("Execution cancellation truth")
struct ExecutionCancellationContractTests {
    @Test("Observe and cancel backend capabilities are independent")
    func capabilitiesAreIndependent() {
        let monitoringOnly: ExternalOperationBackendCapabilities = .monitoringOnly
        let cancellationOnly: ExternalOperationBackendCapabilities = [.cancel]

        #expect(monitoringOnly.canObserve)
        #expect(!monitoringOnly.canCancel)
        #expect(!cancellationOnly.canObserve)
        #expect(cancellationOnly.canCancel)
    }

    @Test("Monitoring-only backend records unsupported cancellation without claiming termination")
    func monitoringOnlyCancellationIsUnsupported() {
        let running = ExecutionControlState(observedExecution: .running)
        let result = ExecutionControlReducer.reduce(
            running,
            event: .requestCancellation(.graceful),
            backendCapabilities: .monitoringOnly
        )

        #expect(result.disposition == .applied)
        #expect(result.state.desiredExecution == .cancelled)
        #expect(result.state.desiredCancellation == .graceful)
        #expect(result.state.observedExecution == .running)
        #expect(result.state.observedCancellation == .unsupported)
    }

    @Test("Supported cancellation requires authoritative confirmation")
    func supportedCancellationTransition() {
        let capabilities: ExternalOperationBackendCapabilities = [.observe, .cancel]
        var state = ExecutionControlState(observedExecution: .running)

        state = ExecutionControlReducer.reduce(
            state,
            event: .requestCancellation(.graceful),
            backendCapabilities: capabilities
        ).state
        #expect(state.observedCancellation == .requestPending)
        #expect(state.observedExecution == .running)

        state = ExecutionControlReducer.reduce(
            state,
            event: .backendAcceptedCancellation,
            backendCapabilities: capabilities
        ).state
        #expect(state.observedCancellation == .accepted)
        #expect(state.observedExecution == .running)

        state = ExecutionControlReducer.reduce(
            state,
            event: .terminationStarted,
            backendCapabilities: capabilities
        ).state
        #expect(state.observedCancellation == .terminating)
        #expect(state.observedExecution == .running)

        state = ExecutionControlReducer.reduce(
            state,
            event: .cancellationConfirmed,
            backendCapabilities: capabilities
        ).state
        #expect(state.observedCancellation == .cancelled)
        #expect(state.observedExecution == .cancelled)
    }

    @Test("Cancellation strength is monotonic and escalation is explicit")
    func cancellationIntentCannotBeDowngraded() {
        let capabilities: ExternalOperationBackendCapabilities = [.observe, .cancel]
        let running = ExecutionControlState(observedExecution: .running)
        let graceful = ExecutionControlReducer.reduce(
            running,
            event: .requestCancellation(.graceful),
            backendCapabilities: capabilities
        )
        let immediate = ExecutionControlReducer.reduce(
            graceful.state,
            event: .requestCancellation(.immediate),
            backendCapabilities: capabilities
        )
        let attemptedDowngrade = ExecutionControlReducer.reduce(
            immediate.state,
            event: .requestCancellation(.graceful),
            backendCapabilities: capabilities
        )

        #expect(graceful.state.desiredCancellation == .graceful)
        #expect(immediate.disposition == .applied)
        #expect(immediate.state.desiredCancellation == .immediate)
        #expect(attemptedDowngrade.disposition == .weakerCancellationIgnored)
        #expect(attemptedDowngrade.state == immediate.state)

        for previousObservation in [
            ExecutionCancellationObservedState.accepted,
            .terminating,
            .inDoubt,
        ] {
            let acceptedGraceful = ExecutionControlState(
                desiredExecution: .cancelled,
                observedExecution: .running,
                desiredCancellation: .graceful,
                observedCancellation: previousObservation
            )
            let escalation = ExecutionControlReducer.reduce(
                acceptedGraceful,
                event: .requestCancellation(.immediate),
                backendCapabilities: capabilities
            )

            #expect(escalation.disposition == .applied)
            #expect(escalation.state.desiredCancellation == .immediate)
            #expect(escalation.state.observedCancellation == .requestPending)
        }
    }

    @Test("Rejected unsupported and indeterminate cancellation attempts can be retried")
    func cancellationAttemptCanBeRetriedWithoutChangingIntent() {
        let cancellable: ExternalOperationBackendCapabilities = [.observe, .cancel]
        let monitoringOnly: ExternalOperationBackendCapabilities = .monitoringOnly
        let running = ExecutionControlState(observedExecution: .running)

        let requested = ExecutionControlReducer.reduce(
            running,
            event: .requestCancellation(.graceful),
            backendCapabilities: cancellable
        ).state
        let duplicatePending = ExecutionControlReducer.reduce(
            requested,
            event: .requestCancellation(.graceful),
            backendCapabilities: cancellable
        )
        #expect(duplicatePending.disposition == .idempotent)

        let rejected = ExecutionControlReducer.reduce(
            requested,
            event: .backendRejectedCancellation,
            backendCapabilities: cancellable
        ).state
        let retriedAfterRejection = ExecutionControlReducer.reduce(
            rejected,
            event: .requestCancellation(.graceful),
            backendCapabilities: cancellable
        )
        #expect(retriedAfterRejection.disposition == .applied)
        #expect(retriedAfterRejection.state.observedCancellation == .requestPending)

        let unsupported = ExecutionControlReducer.reduce(
            running,
            event: .requestCancellation(.graceful),
            backendCapabilities: monitoringOnly
        ).state
        let retriedAfterCapabilityUpgrade = ExecutionControlReducer.reduce(
            unsupported,
            event: .requestCancellation(.graceful),
            backendCapabilities: cancellable
        )
        #expect(retriedAfterCapabilityUpgrade.disposition == .applied)
        #expect(retriedAfterCapabilityUpgrade.state.observedCancellation == .requestPending)

        let inDoubt = ExecutionControlReducer.reduce(
            requested,
            event: .observationBecameIndeterminate,
            backendCapabilities: cancellable
        ).state
        let retriedAfterIndeterminate = ExecutionControlReducer.reduce(
            inDoubt,
            event: .requestCancellation(.graceful),
            backendCapabilities: cancellable
        )
        #expect(retriedAfterIndeterminate.disposition == .applied)
        #expect(retriedAfterIndeterminate.state.observedCancellation == .requestPending)
    }

    @Test("Execution completion racing cancellation is completed before cancel")
    func completionBeforeCancellation() {
        let capabilities: ExternalOperationBackendCapabilities = [.observe, .cancel]
        let requested = ExecutionControlReducer.reduce(
            .init(observedExecution: .running),
            event: .requestCancellation(.immediate),
            backendCapabilities: capabilities
        ).state
        let completed = ExecutionControlReducer.reduce(
            requested,
            event: .executionCompleted,
            backendCapabilities: capabilities
        )

        #expect(completed.disposition == .applied)
        #expect(completed.state.observedExecution == .completed)
        #expect(completed.state.observedCancellation == .completedBeforeCancel)
    }

    @Test("Rejected and indeterminate cancellation remain distinct from cancelled")
    func rejectedAndInDoubtTransitions() {
        let capabilities: ExternalOperationBackendCapabilities = [.cancel]
        let requested = ExecutionControlReducer.reduce(
            .init(observedExecution: .running),
            event: .requestCancellation(.graceful),
            backendCapabilities: capabilities
        ).state
        let rejected = ExecutionControlReducer.reduce(
            requested,
            event: .backendRejectedCancellation,
            backendCapabilities: capabilities
        ).state

        #expect(rejected.observedExecution == .running)
        #expect(rejected.observedCancellation == .rejected)

        let inDoubt = ExecutionControlReducer.reduce(
            rejected,
            event: .observationBecameIndeterminate,
            backendCapabilities: capabilities
        ).state
        #expect(inDoubt.observedExecution == .inDoubt)
        #expect(inDoubt.observedCancellation == .inDoubt)
        #expect(inDoubt.observedExecution != .cancelled)
    }

    @Test("Cancellation confirmation without intent is rejected")
    func cancellationConfirmationRequiresIntent() {
        let initial = ExecutionControlState(observedExecution: .running)
        let result = ExecutionControlReducer.reduce(
            initial,
            event: .cancellationConfirmed,
            backendCapabilities: [.cancel]
        )

        #expect(result.disposition == .invalidTransition)
        #expect(result.state == initial)
    }
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func fixedUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func installationID(_ value: Int) -> RunBrokerInstallationID {
    .init(rawValue: fixedUUID(value))
}

private func storeID(_ value: Int) -> RunBrokerStoreID {
    .init(rawValue: fixedUUID(value))
}

private func executionID(_ value: Int) -> RunBrokerExecutionID {
    .init(rawValue: fixedUUID(value))
}

private func operationID(_ value: Int) -> RunBrokerOperationID {
    .init(rawValue: fixedUUID(value))
}

private func authority(_ value: Int, epoch: UInt64) -> RunBrokerAuthority {
    .init(
        id: .init(rawValue: fixedUUID(value)),
        epoch: .init(rawValue: epoch)
    )
}

private func claimRecord(
    execution: Int,
    operation: Int,
    authority recordAuthority: RunBrokerAuthority? = nil,
    effects: [ExecutionEffectClaim],
    state: DurableExecutionClaimState = .active
) -> DurableExecutionClaimRecord {
    .init(
        storeID: storeID(900),
        operationID: operationID(operation),
        executionID: executionID(execution),
        authority: recordAuthority ?? authority(execution, epoch: 1),
        effects: effects,
        state: state,
        createdAt: fixedDate
    )
}

private func admissionRequest(
    execution: Int,
    operation: Int,
    authority requestAuthority: RunBrokerAuthority? = nil,
    effects: [ExecutionEffectClaim]
) -> ExecutionAdmissionRequest {
    .init(
        storeID: storeID(900),
        operationID: operationID(operation),
        executionID: executionID(execution),
        authority: requestAuthority ?? authority(execution, epoch: 1),
        effects: effects
    )
}

private func denials(in decision: ExecutionAdmissionDecision) -> [ExecutionAdmissionDenial] {
    guard case .denied(let values) = decision else { return [] }
    return values
}

private func hasDenial(
    _ expected: ExecutionAdmissionDenial,
    in decision: ExecutionAdmissionDecision
) -> Bool {
    denials(in: decision).contains(expected)
}

private func hasEffectConflict(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .effectConflict = $0 { return true }
        return false
    }
}

private func hasUnknownEffectDenial(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .unknownOrMalformedEffect = $0 { return true }
        return false
    }
}

private func hasTombstoneDenial(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .operationTombstoned = $0 { return true }
        return false
    }
}

private func hasStaleEpochDenial(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .staleAuthorityEpoch = $0 { return true }
        return false
    }
}

private func hasAuthorityConflict(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .authorityConflict = $0 { return true }
        return false
    }
}

private func hasOperationIdentityConflict(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .operationIdentityConflict = $0 { return true }
        return false
    }
}

private func hasDuplicateOperationDenial(_ decision: ExecutionAdmissionDecision) -> Bool {
    denials(in: decision).contains {
        if case .duplicateOperationRecords = $0 { return true }
        return false
    }
}
