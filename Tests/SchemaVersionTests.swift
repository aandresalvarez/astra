import Foundation
import CoreData
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Schema Versioning")
struct SchemaVersionTests {
    @Test("SchemaV1 declares all 10 model types")
    func v1ModelCount() {
        #expect(ASTRASchemaV1.models.count == 10)
    }

    @Test("SchemaV2 declares all 10 model types")
    func v2ModelCount() {
        #expect(ASTRASchemaV2.models.count == 10)
    }

    @Test("SchemaV3 declares all 10 model types")
    func v3ModelCount() {
        #expect(ASTRASchemaV3.models.count == 10)
    }

    @Test("SchemaV4 declares all 10 model types")
    func v4ModelCount() {
        #expect(ASTRASchemaV4.models.count == 10)
    }

    @Test("SchemaV5 declares all 10 model types")
    func v5ModelCount() {
        #expect(ASTRASchemaV5.models.count == 10)
    }

    @Test("SchemaV6 declares all 10 model types")
    func v6ModelCount() {
        #expect(ASTRASchemaV6.models.count == 10)
    }

    @Test("SchemaV7 declares all 10 model types")
    func v7ModelCount() {
        #expect(ASTRASchemaV7.models.count == 10)
    }

    @Test("Historical V7 and V8 schemas keep frozen core model identities")
    func historicalV7AndV8SchemasKeepFrozenCoreModelIdentities() {
        #expect(ASTRASchemaV7.models.contains { $0 == ASTRASchemaV7.Workspace.self })
        #expect(ASTRASchemaV7.models.contains { $0 == ASTRASchemaV7.AgentTask.self })
        #expect(!ASTRASchemaV7.models.contains { $0 == Workspace.self })
        #expect(!ASTRASchemaV7.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.Workspace.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.AgentTask.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == Workspace.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.WorkspaceApp.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == WorkspaceApp.self })
    }

    @Test("SchemaV1 version identifier is 1.0.0")
    func v1VersionIdentifier() {
        #expect(ASTRASchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("SchemaV2 version identifier is 2.0.0")
    func v2VersionIdentifier() {
        #expect(ASTRASchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test("SchemaV3 version identifier is 3.0.0")
    func v3VersionIdentifier() {
        #expect(ASTRASchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
    }

    @Test("SchemaV4 version identifier is 4.0.0")
    func v4VersionIdentifier() {
        #expect(ASTRASchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
    }

    @Test("SchemaV5 version identifier is 5.0.0")
    func v5VersionIdentifier() {
        #expect(ASTRASchemaV5.versionIdentifier == Schema.Version(5, 0, 0))
    }

    @Test("SchemaV6 version identifier is 6.0.0")
    func v6VersionIdentifier() {
        #expect(ASTRASchemaV6.versionIdentifier == Schema.Version(6, 0, 0))
    }

    @Test("SchemaV7 version identifier is 7.0.0")
    func v7VersionIdentifier() {
        #expect(ASTRASchemaV7.versionIdentifier == Schema.Version(7, 0, 0))
    }

    @Test("SchemaV8 declares 15 model types (10 + 5 Workspace App models)")
    func v8ModelCount() {
        #expect(ASTRASchemaV8.models.count == 15)
    }

    @Test("SchemaV8 version identifier is 8.0.0")
    func v8VersionIdentifier() {
        #expect(ASTRASchemaV8.versionIdentifier == Schema.Version(8, 0, 0))
    }

    @Test("SchemaV9 declares 16 model types (V8 + Google OAuth account profiles)")
    func v9ModelCount() {
        #expect(ASTRASchemaV9.models.count == 16)
        #expect(ASTRASchemaV9.models.contains { $0 == ASTRASchemaV9.GoogleOAuthAccountProfile.self })
        #expect(!ASTRASchemaV9.models.contains { $0 == GoogleOAuthAccountProfile.self })
    }

    @Test("SchemaV9 version identifier is 9.0.0")
    func v9VersionIdentifier() {
        #expect(ASTRASchemaV9.versionIdentifier == Schema.Version(9, 0, 0))
    }

    @Test("SchemaV10 declares 16 model types and keeps pack profile fields on Workspace")
    func v10ModelCountAndPackProfileFields() {
        #expect(ASTRASchemaV10.models.count == 16)
        #expect(ASTRASchemaV10.models.contains { $0 == ASTRASchemaV10.GoogleOAuthAccountProfile.self })
        #expect(!ASTRASchemaV10.models.contains { $0 == AgentTask.self })
    }

    @Test("SchemaV10 version identifier is 10.0.0")
    func v10VersionIdentifier() {
        #expect(ASTRASchemaV10.versionIdentifier == Schema.Version(10, 0, 0))
    }

    @Test("SchemaV11 declares 16 model types and keeps typed runtime state fields")
    func v11ModelCountAndTypedRuntimeStateFields() {
        #expect(ASTRASchemaV11.models.count == 16)
        #expect(ASTRASchemaV11.models.contains { $0 == ASTRASchemaV11.AgentTask.self })
        #expect(ASTRASchemaV11.models.contains { $0 == ASTRASchemaV11.TaskRun.self })
        #expect(!ASTRASchemaV11.models.contains { $0 == AgentTask.self })
        #expect(!ASTRASchemaV11.models.contains { $0 == TaskRun.self })

        let task = ASTRASchemaV11.AgentTask()
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
        #expect(task.runtimePermissionGrantsJSON == "[]")

        let run = ASTRASchemaV11.TaskRun()
        #expect(run.providerLaunchSignatureJSON == nil)
    }

    @Test("SchemaV11 version identifier is 11.0.0")
    func v11VersionIdentifier() {
        #expect(ASTRASchemaV11.versionIdentifier == Schema.Version(11, 0, 0))
    }

    @Test("Runtime-only V12 freezes the orphaned 16-entity shape")
    func runtimeOnlyV12IsFrozen() {
        #expect(ASTRASchemaV12RuntimeOnly.models.count == 16)
        #expect(ASTRASchemaV12RuntimeOnly.models.contains { $0 == ASTRASchemaV12RuntimeOnly.AgentTask.self })
        #expect(!ASTRASchemaV12RuntimeOnly.models.contains { $0 == AgentTask.self })
        #expect(!ASTRASchemaV12RuntimeOnly.models.contains { $0 == FeedbackReport.self })

        let task = ASTRASchemaV12RuntimeOnly.AgentTask()
        #expect(task.runtimeExplicitlySelected == false)
    }

    @Test("Production V12 freezes the 17-entity feedback shape")
    func productionV12IsFrozen() {
        #expect(ASTRASchemaV12.models.count == 17)
        #expect(ASTRASchemaV12.models.contains { $0 == ASTRASchemaV12RuntimeOnly.AgentTask.self })
        #expect(ASTRASchemaV12.models.contains { $0 == ASTRASchemaV12Models.FeedbackReport.self })
        #expect(!ASTRASchemaV12.models.contains { $0 == AgentTask.self })
        #expect(!ASTRASchemaV12.models.contains { $0 == FeedbackReport.self })
    }

    @Test("Feedback-only V12 freezes the historical V11 task shape plus feedback")
    func feedbackOnlyV12IsFrozen() {
        #expect(ASTRASchemaV12FeedbackOnly.models.count == 17)
        #expect(ASTRASchemaV12FeedbackOnly.models.contains { $0 == ASTRASchemaV11.AgentTask.self })
        #expect(ASTRASchemaV12FeedbackOnly.models.contains { $0 == ASTRASchemaV12Models.FeedbackReport.self })
        #expect(!ASTRASchemaV12FeedbackOnly.models.contains { $0 == ASTRASchemaV12RuntimeOnly.AgentTask.self })
        #expect(!ASTRASchemaV12FeedbackOnly.models.contains { $0 == AgentTask.self })
    }

    @Test("SchemaV13 freezes the reconciled production task graph")
    func v13IsFrozen() {
        #expect(ASTRASchemaV13.models.count == 18)
        #expect(ASTRASchemaV13.models.contains { $0 == ASTRASchemaV12RuntimeOnly.AgentTask.self })
        #expect(ASTRASchemaV13.models.contains { $0 == ASTRASchemaV12Models.FeedbackReport.self })
        #expect(ASTRASchemaV13.models.contains { $0 == ASTRASchemaV13Models.PersistentStoreMigrationRecord.self })
        #expect(!ASTRASchemaV13.models.contains { $0 == AgentTask.self })
    }

    @MainActor
    @Test("SchemaV14 declares current models and task-owned canvas preference")
    func v14ModelCountAndCanvasPreferenceField() throws {
        #expect(ASTRASchemaV14.models.count == 18)
        #expect(ASTRASchemaV14.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV14.models.contains { $0 == FeedbackReport.self })
        #expect(ASTRASchemaV14.models.contains { $0 == PersistentStoreMigrationRecord.self })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Typed State", goal: "Verify typed state")
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        try context.save()

        #expect(task.runtimeExplicitlySelected == false)
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
        #expect(task.runtimePermissionGrantsJSON == "[]")
        #expect(task.rememberedWorkspaceCanvasItemRawValue == nil)
        #expect(run.providerLaunchSignatureJSON == nil)
    }

    @MainActor
    @Test("SchemaV15 adds durable task turn requests")
    func v15ModelCountAndTurnRequestField() throws {
        #expect(ASTRASchemaV15.models.count == 19)
        #expect(ASTRASchemaV15.models.contains { $0 == ASTRASchemaV15Models.TaskTurnRequest.self })
        #expect(!ASTRASchemaV15.models.contains { $0 == TaskTurnRequest.self })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Durable turn", goal: "Persist user intent")
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1)
        context.insert(request)
        try context.save()

        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).map(\.id) == [request.id])
        #expect(request.state == .waitingForWorker)
    }

    @MainActor
    @Test("SchemaV16 persists every execution request kind with immutable launch inputs")
    func v16UniversalExecutionRequestContract() throws {
        #expect(ASTRASchemaV16.models.count == 19)
        #expect(ASTRASchemaV16.models.contains { $0 == TaskTurnRequest.self })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let task = AgentTask(
            title: "Universal request",
            goal: "Preserve execution intent",
            tokenBudget: 12_345,
            model: "test-model",
            runtime: .codexCLI
        )
        task.runtimeExplicitlySelected = true
        task.maxTurns = 9
        task.useAgentTeam = true
        task.teamSize = 4
        task.teamInstructions = "Coordinate deterministically."
        context.insert(task)

        let claim = TaskExecutionResourceClaim(
            kind: .workspace,
            key: "/tmp/universal-request",
            access: .shared
        )
        for (index, kind) in TaskExecutionRequestKind.allCases.enumerated() {
            context.insert(TaskTurnRequest(
                task: task,
                messageEventID: UUID(),
                sequence: index + 1,
                kind: kind,
                resourceClaims: [claim]
            ))
        }
        try context.save()

        let requests = try TaskTurnRequestRepository.requests(for: task, in: context)
        #expect(requests.map(\.kind) == TaskExecutionRequestKind.allCases)
        #expect(requests.allSatisfy { $0.sourceEventID == $0.messageEventID })
        #expect(requests.allSatisfy { $0.runtimeIDSnapshot == AgentRuntimeID.codexCLI.rawValue })
        #expect(requests.allSatisfy { $0.modelSnapshot == "test-model" })
        #expect(requests.allSatisfy { $0.tokenBudgetSnapshot == 12_345 })
        #expect(requests.allSatisfy { $0.executionPolicySnapshot?.maxTurns == 9 })
        #expect(requests.allSatisfy { $0.executionPolicySnapshot?.teamSize == 4 })
        #expect(requests.allSatisfy { $0.resourceClaims == [claim] })
    }

    @Test("SchemaV12 version identifier is 12.0.0")
    func v12VersionIdentifier() {
        #expect(ASTRASchemaV12.versionIdentifier == Schema.Version(12, 0, 0))
    }

    @Test("SchemaV13 version identifier is 13.0.0")
    func v13VersionIdentifier() {
        #expect(ASTRASchemaV13.versionIdentifier == Schema.Version(13, 0, 0))
    }

    @Test("SchemaV14 version identifier is 14.0.0")
    func v14VersionIdentifier() {
        #expect(ASTRASchemaV14.versionIdentifier == Schema.Version(14, 0, 0))
    }

    @Test("SchemaV15 version identifier is 15.0.0")
    func v15VersionIdentifier() {
        #expect(ASTRASchemaV15.versionIdentifier == Schema.Version(15, 0, 0))
    }

    @Test("SchemaV16 version identifier is 16.0.0")
    func v16VersionIdentifier() {
        #expect(ASTRASchemaV16.versionIdentifier == Schema.Version(16, 0, 0))
    }

    @Test("Advertised current schema matches the compiled current model")
    func advertisedCurrentSchemaMatchesCompiledModel() {
        #expect(ASTRASchema.currentVersion == 16)
        #expect(ASTRASchemaV16.versionIdentifier == Schema.Version(ASTRASchema.currentVersion, 0, 0))
    }

    @Test("Migration plan lists SchemaV1 through SchemaV16")
    func migrationPlanHasVersions() {
        #expect(ASTRAMigrationPlan.schemas.count == 16)
    }

    @Test("Migration plan has V1 to V16 lightweight stages")
    func migrationPlanHasStage() {
        #expect(ASTRAMigrationPlan.stages.count == 15)
    }

    @Test("Orphan recovery plan keeps the colliding V12 isolated")
    func orphanRecoveryPlanIsIsolated() {
        // The isolated V12 recovery plans migrate their colliding-V12 store
        // forward to current: V12x → V13 → V14 → V15 → V16.
        #expect(ASTRAOrphanedV12MigrationPlan.schemas.count == 5)
        #expect(ASTRAOrphanedV12MigrationPlan.stages.count == 4)
        #expect(ASTRAFeedbackOnlyV12MigrationPlan.schemas.count == 5)
        #expect(ASTRAFeedbackOnlyV12MigrationPlan.stages.count == 4)
    }

    @Test("Frozen V12 and V13 schemas match all observed on-disk fingerprints")
    func frozenV12FingerprintsMatchObservedStores() throws {
        #expect(try modelDigest(for: ASTRASchemaV12RuntimeOnly.self) == "gOyhETqn0JsdoYEzwTW4HL0JczNjjAZAP1RnTqyP2OVdSMByOnWSLe1yi6MGcwuSHctPUYlM7dhh3FoKv2Xrug==")
        #expect(try modelDigest(for: ASTRASchemaV12FeedbackOnly.self) == "MMAHCJmoTDsXR0SV6RF+goUZ2DBiNuwEtnq3KS3v0jcU8kGeSbQeZrrAeIFkfK4/xgALX2J2CrYJYdsoc9P0sg==")
        #expect(try modelDigest(for: ASTRASchemaV12.self) == "8A20+TTf27Ld2ivltxATZ9CEzlihL4bWotqJTiVHIMS+OB7pT8DKDKjw48YapWPv4ZpglJnfTLrpPJ8XZD4bkw==")
        #expect(try modelDigest(for: ASTRASchemaV13.self) == "F8EAtnO6XEb1sTTzkmpQUCUI4Rhv0yDneoWeElmC/fO2XA9uaRoyDqz1e68zWR6m3tZQ/tFZp3p+95HDlzt+4g==")
    }

    @Test("Canonical V15 schema fingerprint stays frozen")
    func frozenV15FingerprintMatchesCanonicalStore() throws {
        let digest = try modelDigest(for: ASTRASchemaV15.self)
        #expect(
            digest == "JHH5ue6NwPzbFrSTCEmxo8VfUAVJouJt4yYYetH6viYRqY/DdG8CNMdMGaRv6e0bMuvTflo4EaLVxwwbgix/Lg==",
            "Actual canonical V15 digest: \(digest)"
        )
        // The canonical durable-turn V15 store uses this checksum. The
        // incompatible external-operation branch reused 15.0.0 with checksum
        // fjNnIAoVBrprvCS0R9NHWeJKEu/l0I7XjMZHs9trXEk=; pinning the canonical
        // value prevents another same-version model collision.
        #expect(
            try modelChecksum(for: ASTRASchemaV15.self) == "20EX/Ki6+0dMVN122sYI+u0kxAw7mMDBSRVharTGbbQ="
        )
    }

    @Test("Frozen external-operation V15 schemas match both observed sub-shapes")
    func frozenExternalOperationV15FingerprintsMatchObservedStores() throws {
        #expect(ASTRASchemaV15ExternalOperation.versionIdentifier == Schema.Version(15, 0, 0))
        #expect(ASTRASchemaV15ExternalOperationInitial.versionIdentifier == Schema.Version(15, 0, 0))
        #expect(ASTRASchemaV15ExternalOperation.models.count == 19)
        #expect(ASTRASchemaV15ExternalOperationInitial.models.count == 19)
        #expect(ASTRASchemaV15ExternalOperation.models.contains {
            $0 == ASTRASchemaV15ExternalOperationModels.TaskExternalOperation.self
        })
        #expect(ASTRASchemaV15ExternalOperationInitial.models.contains {
            $0 == ASTRASchemaV15ExternalOperationInitialModels.TaskExternalOperation.self
        })

        // These are the on-disk checksums the external-operation branch's Dev
        // builds wrote (initial pre-launchResourceKey shape, then the final
        // shape after the optional field was added mid-branch). The initial
        // value matches the observed store checksum documented alongside the
        // canonical V15 pin above. Shape detection routes on these; drifting
        // either frozen declaration would silently orphan those stores again.
        let finalChecksum = try modelChecksum(for: ASTRASchemaV15ExternalOperation.self)
        #expect(
            finalChecksum == "Y4VRug2MsVnb+dlybKvYqRGpwBl3EHlI5Ukk3Eqttr8=",
            "Actual final external-operation V15 checksum: \(finalChecksum)"
        )
        let initialChecksum = try modelChecksum(for: ASTRASchemaV15ExternalOperationInitial.self)
        #expect(
            initialChecksum == "fjNnIAoVBrprvCS0R9NHWeJKEu/l0I7XjMZHs9trXEk=",
            "Actual initial external-operation V15 checksum: \(initialChecksum)"
        )

        // The isolated recovery plans mirror the colliding-V12 precedent:
        // each colliding 15.0.0 shape migrates to V16 outside the normal plan.
        #expect(ASTRAExternalOperationV15MigrationPlan.schemas.count == 2)
        #expect(ASTRAExternalOperationV15MigrationPlan.stages.count == 1)
        #expect(ASTRAExternalOperationInitialV15MigrationPlan.schemas.count == 2)
        #expect(ASTRAExternalOperationInitialV15MigrationPlan.stages.count == 1)
    }

    @MainActor
    @Test("External-operation V15 store is rejected by the canonical plan and recovered through an isolated copy")
    func externalOperationV15StoreRecoversThroughIsolatedPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v15-external-operation-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("recovery.store")
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
        let reportID = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!

        do {
            var sourceContainer: ModelContainer? = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV15ExternalOperation.self),
                configurations: [ModelConfiguration(url: sourceURL)]
            )
            let context = try #require(sourceContainer?.mainContext)
            let task = AgentTask(title: "External-operation V15 task", goal: "Survive the V15 collision")
            task.id = taskID
            context.insert(task)

            let report = FeedbackReport(
                id: reportID,
                installationID: "installation-v15",
                evidenceWindowStart: Date(timeIntervalSince1970: 100),
                evidenceWindowEnd: Date(timeIntervalSince1970: 200),
                consentVersion: "v1"
            )
            context.insert(report)

            for index in 0..<2 {
                let operation = ASTRASchemaV15ExternalOperationModels.TaskExternalOperation()
                operation.taskID = taskID
                operation.externalIdentity = "job-\(index)"
                operation.backendKindRaw = "workspace_shell"
                operation.backendJobID = "job-\(index)"
                context.insert(operation)
            }
            try context.save()
            sourceContainer = nil
        }
        let sourceBytes = try Data(contentsOf: sourceURL)

        // The version-based compatibility preflight cannot catch this store:
        // it reads 15.0.0 and reports it openable by this binary.
        #expect(
            PersistentStoreCompatibilityService.assess(
                storeURL: sourceURL,
                latestSupportedSchemaVersion: ASTRASchema.currentVersion
            ) == .compatible(storeSchemaVersion: 15)
        )
        // Failure signature this recovery path exists for: the canonical plan
        // resolves 15.0.0 to the canonical checksum, so Core Data rejects the
        // incompatible store before any migration stage can run.
        #expect(throws: (any Error).self) {
            _ = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: sourceURL)]
            )
        }

        #expect(try PersistentStoreModelShapeService.shape(ofStoreAt: sourceURL) == .externalOperationV15)
        #expect(
            OrphanedV12StoreMigrator.migrationProbe(storeURL: sourceURL)
                == .required(shape: .externalOperationV15)
        )

        let report = try OrphanedV12StoreMigrator.migrateCopy(
            from: sourceURL,
            to: destinationURL
        )
        #expect(report.sourceShapeRaw == "external_operation_v15")
        #expect(report.sourceSchemaVersion == 15)
        #expect(report.droppedRowCounts == ["ZTASKEXTERNALOPERATION": 2])
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: destinationURL
        )
        #expect(PersistentStoreCompatibilityService.schemaVersion(from: metadata) == ASTRASchema.currentVersion)
        let entityHashes = try #require(metadata["NSStoreModelVersionHashes"] as? [String: Any])
        #expect(entityHashes["TaskExternalOperation"] == nil)
        #expect(entityHashes["TaskTurnRequest"] != nil)

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: destinationURL)]
        )
        let context = migratedContainer.mainContext
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(migratedTask.id == taskID)
        #expect(migratedTask.title == "External-operation V15 task")
        let migratedReport = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)
        #expect(migratedReport.id == reportID)
        #expect(try context.fetch(FetchDescriptor<TaskTurnRequest>()).isEmpty)
        let migrationRecord = try #require(
            try context.fetch(FetchDescriptor<PersistentStoreMigrationRecord>()).first
        )
        #expect(migrationRecord.sourceSchemaVersion == 15)
        #expect(migrationRecord.sourceShapeRaw == "external_operation_v15")
        #expect(migrationRecord.destinationSchemaVersion == ASTRASchema.currentVersion)
        #expect(migrationRecord.reason == "reconcile_colliding_v15_shapes")
    }

    @MainActor
    @Test("Pre-launchResourceKey external-operation V15 store recovers through its own isolated plan")
    func initialExternalOperationV15StoreRecoversThroughIsolatedPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v15-external-operation-initial-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("recovery.store")
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!

        do {
            var sourceContainer: ModelContainer? = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV15ExternalOperationInitial.self),
                configurations: [ModelConfiguration(url: sourceURL)]
            )
            let context = try #require(sourceContainer?.mainContext)
            let task = AgentTask(title: "Initial-shape V15 task", goal: "Survive the earlier sub-shape")
            task.id = taskID
            context.insert(task)
            let operation = ASTRASchemaV15ExternalOperationInitialModels.TaskExternalOperation()
            operation.taskID = taskID
            operation.externalIdentity = "job-initial"
            context.insert(operation)
            try context.save()
            sourceContainer = nil
        }

        #expect(throws: (any Error).self) {
            _ = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: sourceURL)]
            )
        }
        #expect(
            try PersistentStoreModelShapeService.shape(ofStoreAt: sourceURL)
                == .externalOperationInitialV15
        )
        #expect(
            OrphanedV12StoreMigrator.migrationProbe(storeURL: sourceURL)
                == .required(shape: .externalOperationInitialV15)
        )

        let report = try OrphanedV12StoreMigrator.migrateCopy(
            from: sourceURL,
            to: destinationURL
        )
        #expect(report.sourceShapeRaw == "external_operation_initial_v15")
        #expect(report.sourceSchemaVersion == 15)
        #expect(report.droppedRowCounts == ["ZTASKEXTERNALOPERATION": 1])

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: destinationURL)]
        )
        let context = migratedContainer.mainContext
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(migratedTask.id == taskID)
        #expect(try context.fetch(FetchDescriptor<TaskTurnRequest>()).isEmpty)
        let migrationRecord = try #require(
            try context.fetch(FetchDescriptor<PersistentStoreMigrationRecord>()).first
        )
        #expect(migrationRecord.sourceSchemaVersion == 15)
        #expect(migrationRecord.sourceShapeRaw == "external_operation_initial_v15")
    }

    @MainActor
    @Test("Canonical V15 store is never routed through external-operation recovery")
    func canonicalV15StoreIsNotRoutedThroughExternalOperationRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v15-canonical-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")

        var container: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV15.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        #expect(container != nil)
        container = nil

        #expect(try PersistentStoreModelShapeService.shape(ofStoreAt: storeURL) == .other)
        #expect(OrphanedV12StoreMigrator.migrationProbe(storeURL: storeURL) == .notRequired)
    }

    @Test("ModelContainer can be created with versioned schema")
    func containerCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        #expect(container.schema.entities.count == 19)
    }

    @MainActor
    @Test("Versioned container supports full CRUD cycle")
    func crudCycle() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext

        let workspace = Workspace(name: "Test", primaryPath: "/tmp/schema-test")
        context.insert(workspace)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
        #expect(workspace.isStarred == false)
        #expect(workspace.activeWorkingPath == nil)
        #expect(workspace.activeExecutionEnvironmentJSON == nil)

        let skill = Skill(name: "Reader", allowedTools: ["Read"])
        skill.workspace = workspace
        context.insert(skill)

        let connector = Connector(name: "API", serviceType: "rest_api")
        connector.workspace = workspace
        context.insert(connector)

        let tool = LocalTool(name: "Build", command: "swift build")
        tool.workspace = workspace
        context.insert(tool)

        #expect(skill.originPackageID == nil)
        #expect(connector.originPackageID == nil)
        #expect(tool.originPackageID == nil)

        let task = AgentTask(title: "Test Task", goal: "Do something", workspace: workspace)
        task.skills = [skill]
        #expect(task.executionRootPath == nil)
        #expect(ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON).isHost)
        context.insert(task)

        let run = TaskRun(task: task)
        #expect(ExecutionEnvironmentStore.decode(run.executionEnvironmentSnapshotJSON).isHost)
        context.insert(run)

        let event = TaskEvent(task: task, type: "test", run: run)
        context.insert(event)

        let artifact = Artifact(task: task, type: "file", path: "/tmp/out.txt")
        context.insert(artifact)

        let template = TaskTemplate(name: "Build", mainGoal: "Build it", workspace: workspace)
        context.insert(template)
        #expect(template.originPackageID == nil)

        let schedule = TaskSchedule(name: "Hourly", workspace: workspace)
        context.insert(schedule)
        #expect(schedule.resolvedRuntimeID == .claudeCode)

        try context.save()

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.count == 1)
        #expect(workspaces[0].tasks.count == 1)
        #expect(workspaces[0].skills.count == 1)
        #expect(workspaces[0].connectors.count == 1)
        #expect(workspaces[0].localTools.count == 1)
        #expect(workspaces[0].templates.count == 1)
        #expect(workspaces[0].schedules.count == 1)

        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        #expect(tasks[0].runs.count == 1)
        #expect(tasks[0].events.count == 1)
        #expect(tasks[0].artifacts.count == 1)
        #expect(tasks[0].skills.count == 1)
    }

    @MainActor
    @Test("Populated SchemaV13 store migrates to V14 with an empty canvas preference")
    func v13StoreMigratesToTaskOwnedCanvasPreference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v13-canvas-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        let workspaceID: UUID
        let taskID: UUID

        do {
            let oldContainer = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV13.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = oldContainer.mainContext
            let workspace = ASTRASchemaV12RuntimeOnly.Workspace()
            workspace.name = "V13 Workspace"
            workspace.primaryPath = "/tmp/v13-canvas"
            context.insert(workspace)
            let task = ASTRASchemaV12RuntimeOnly.AgentTask()
            task.title = "V13 Task"
            task.goal = "Preserve relationships"
            task.workspace = workspace
            context.insert(task)
            let run = ASTRASchemaV12RuntimeOnly.TaskRun()
            run.task = task
            context.insert(run)
            try context.save()
            workspaceID = workspace.id
            taskID = task.id
        }

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let workspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(workspace.id == workspaceID)
        #expect(task.id == taskID)
        #expect(task.workspace?.id == workspaceID)
        #expect(task.runs.count == 1)
        #expect(task.rememberedWorkspaceCanvasItemRawValue == nil)
    }

    @MainActor
    @Test("Populated SchemaV15 request migrates to V16 without inventing launch history")
    func v15StoreMigratesToUniversalExecutionRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v15-request-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        let taskID: UUID
        let requestID: UUID
        let eventID = UUID()

        do {
            let oldContainer = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV15.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = oldContainer.mainContext
            let task = AgentTask(title: "V15 task", goal: "Preserve request")
            context.insert(task)
            let request = ASTRASchemaV15Models.TaskTurnRequest()
            request.taskID = task.id
            request.messageEventID = eventID
            request.sequence = 3
            request.stateRawValue = TaskTurnRequestState.waitingForResource.rawValue
            request.blockerSummary = "Waiting before upgrade"
            context.insert(request)
            try context.save()
            taskID = task.id
            requestID = request.id
        }

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let request = try #require(try context.fetch(FetchDescriptor<TaskTurnRequest>()).first)
        #expect(request.id == requestID)
        #expect(request.taskID == taskID)
        #expect(request.messageEventID == eventID)
        #expect(request.sequence == 3)
        #expect(request.state == .waitingForResource)
        #expect(request.blockerSummary == "Waiting before upgrade")
        #expect(request.kind == .followUp)
        #expect(request.runtimeIDSnapshot == nil)
        #expect(request.modelSnapshot == nil)
        #expect(request.tokenBudgetSnapshot == nil)
        #expect(request.executionPolicySnapshot == nil)
        #expect(request.resourceClaims.isEmpty)
    }

    private func modelDigest(for versionedSchema: any VersionedSchema.Type) throws -> String {
        let metadata = try modelMetadata(for: versionedSchema)
        if let digest = metadata["NSStoreModelVersionHashesDigest"] as? String {
            return digest
        }
        if let digest = metadata["NSStoreModelVersionHashesDigest"] as? Data {
            return digest.base64EncodedString()
        }
        throw CocoaError(.coderInvalidValue)
    }

    private func modelChecksum(for versionedSchema: any VersionedSchema.Type) throws -> String {
        let metadata = try modelMetadata(for: versionedSchema)
        guard let checksum = metadata["NSStoreModelVersionChecksumKey"] as? String else {
            throw CocoaError(.coderInvalidValue)
        }
        return checksum
    }

    private func modelMetadata(
        for versionedSchema: any VersionedSchema.Type
    ) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        var container: ModelContainer? = try ModelContainer(
          for: Schema(versionedSchema: versionedSchema),
          configurations: [ModelConfiguration(url: storeURL)]
        )
        #expect(container != nil)
        container = nil

        return try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
    }

    @MainActor
    @Test("SchemaV1 store migrates to current runtime and unread fields")
    func legacyStoreMigratesToCurrentFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV1.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV1.Workspace()
        oldWorkspace.name = "Legacy"
        oldWorkspace.primaryPath = "/tmp/legacy"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV1.AgentTask()
        oldTask.title = "Legacy Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        let oldRun = ASTRASchemaV1.TaskRun()
        oldRun.task = oldTask
        oldRun.output = "done"
        oldContext.insert(oldRun)

        let oldSchedule = ASTRASchemaV1.TaskSchedule()
        oldSchedule.name = "Legacy Schedule"
        oldSchedule.goal = "Review"
        oldSchedule.workspace = oldWorkspace
        oldContext.insert(oldSchedule)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        let migratedTask = try #require(tasks.first)
        #expect(migratedTask.resolvedRuntimeID == .claudeCode)
        #expect(migratedTask.unreadAt == nil)
        #expect((migratedTask.runtimePermissionOpenRequestsJSON ?? "[]") == "[]")
        #expect((migratedTask.runtimePermissionGrantsJSON ?? "[]") == "[]")
        #expect(migratedTask.runtimeExplicitlySelected == false)

        let runs = try context.fetch(FetchDescriptor<TaskRun>())
        let migratedRun = try #require(runs.first)
        #expect(migratedRun.runtimeID == nil)
        #expect(migratedRun.providerSessionId == nil)
        #expect(migratedRun.providerVersion == nil)
        #expect(migratedRun.providerLaunchSignatureJSON == nil)

        let schedules = try context.fetch(FetchDescriptor<TaskSchedule>())
        let migratedSchedule = try #require(schedules.first)
        #expect(migratedSchedule.resolvedRuntimeID == .claudeCode)
    }

    @MainActor
    @Test("Production SchemaV12 migrates to current schema with feedback and runtime state intact")
    func productionV12MigratesToCurrentSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-schema-v12-production-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000211")!
        let reportID = UUID(uuidString: "00000000-0000-0000-0000-000000000212")!

        do {
            var oldContainer: ModelContainer? = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV12.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = try #require(oldContainer?.mainContext)
            let task = ASTRASchemaV12RuntimeOnly.AgentTask()
            task.id = taskID
            task.title = "Production V12 task"
            task.runtimeID = "cursor_cli"
            task.runtimeExplicitlySelected = true
            context.insert(task)

            let report = ASTRASchemaV12Models.FeedbackReport(
                id: reportID,
                installationID: "installation-v12",
                intendedOutcome: "Preserve feedback",
                actualResult: "Preserved",
                evidenceWindowStart: Date(timeIntervalSince1970: 100),
                evidenceWindowEnd: Date(timeIntervalSince1970: 200),
                consentVersion: "v1"
            )
            report.taskID = taskID.uuidString
            report.localStatusRaw = "queued"
            context.insert(report)
            try context.save()
            oldContainer = nil
        }

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        let migratedReport = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)

        #expect(migratedTask.id == taskID)
        #expect(migratedTask.runtimeID == "cursor_cli")
        #expect(migratedTask.runtimeExplicitlySelected)
        #expect(migratedReport.id == reportID)
        #expect(migratedReport.installationID == "installation-v12")
        #expect(migratedReport.localStatusRaw == "queued")
        #expect(try context.fetchCount(FetchDescriptor<PersistentStoreMigrationRecord>()) == 0)
    }

    @MainActor
    @Test("Populated SchemaV11 store migrates to current schema without disturbing relationships")
    func v11StoreMigratesToFeedbackReportTable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v11-feedback-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV11.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let oldContext = try #require(oldContainer?.mainContext)
        let workspace = ASTRASchemaV11.Workspace()
        workspace.name = "V11 Workspace"
        workspace.primaryPath = "/tmp/v11-feedback"
        oldContext.insert(workspace)
        let task = ASTRASchemaV11.AgentTask()
        task.title = "V11 Task"
        task.goal = "Preserve me"
        task.workspace = workspace
        oldContext.insert(task)
        let run = ASTRASchemaV11.TaskRun()
        run.task = task
        oldContext.insert(run)
        try oldContext.save()
        let workspaceID = workspace.id
        let taskID = task.id
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(migratedWorkspace.id == workspaceID)
        #expect(migratedTask.id == taskID)
        #expect(migratedTask.workspace?.id == workspaceID)
        #expect(migratedTask.runs.count == 1)
        #expect(try context.fetch(FetchDescriptor<FeedbackReport>()).isEmpty)

        let feedback = FeedbackReport(
            installationID: "installation-v1",
            evidenceWindowStart: Date(timeIntervalSince1970: 1_000),
            evidenceWindowEnd: Date(timeIntervalSince1970: 1_900),
            consentVersion: "consent-v1"
        )
        context.insert(feedback)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<FeedbackReport>()).count == 1)
    }

    @MainActor
    @Test("SchemaV2 store migrates to SchemaV3 unread fields")
    func v2StoreMigratesToUnreadFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v2-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV2.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV2.Workspace()
        oldWorkspace.name = "Legacy V2"
        oldWorkspace.primaryPath = "/tmp/legacy-v2"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV2.AgentTask()
        oldTask.title = "Legacy V2 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        let migratedTask = try #require(tasks.first)
        #expect(migratedTask.resolvedRuntimeID == .claudeCode)
        #expect(migratedTask.unreadAt == nil)
    }

    @MainActor
    @Test("SchemaV3 store migrates to SchemaV4 starred workspace field")
    func v3StoreMigratesToStarredWorkspaceField() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v3-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV3.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV3.Workspace()
        oldWorkspace.name = "Legacy V3"
        oldWorkspace.primaryPath = "/tmp/legacy-v3"
        oldContext.insert(oldWorkspace)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        let migratedWorkspace = try #require(workspaces.first)
        #expect(migratedWorkspace.isStarred == false)
    }

    @MainActor
    @Test("SchemaV4 store migrates to SchemaV5 origin fields")
    func v4StoreMigratesToOriginFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v4-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV4.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV4.Workspace()
        oldWorkspace.name = "Legacy V4"
        oldWorkspace.primaryPath = "/tmp/legacy-v4"
        oldContext.insert(oldWorkspace)

        let oldSkill = ASTRASchemaV4.Skill()
        oldSkill.name = "Legacy Skill"
        oldSkill.workspace = oldWorkspace
        oldContext.insert(oldSkill)

        let oldConnector = ASTRASchemaV4.Connector()
        oldConnector.name = "Legacy Connector"
        oldConnector.workspace = oldWorkspace
        oldContext.insert(oldConnector)

        let oldTool = ASTRASchemaV4.LocalTool()
        oldTool.name = "legacy-tool"
        oldTool.workspace = oldWorkspace
        oldContext.insert(oldTool)

        let oldTemplate = ASTRASchemaV4.TaskTemplate()
        oldTemplate.name = "Legacy Template"
        oldTemplate.workspace = oldWorkspace
        oldContext.insert(oldTemplate)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        #expect(try context.fetch(FetchDescriptor<Skill>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<Connector>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<TaskTemplate>()).first?.originPackageID == nil)
    }

    @MainActor
    @Test("SchemaV5 store migrates to SchemaV6 worktree binding fields")
    func v5StoreMigratesToWorktreeFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v5-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV5.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV5.Workspace()
        oldWorkspace.name = "Legacy V5"
        oldWorkspace.primaryPath = "/tmp/legacy-v5"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV5.AgentTask()
        oldTask.title = "Legacy V5 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.activeWorkingPath == nil)
        #expect(migratedWorkspace.activeExecutionEnvironmentJSON == nil)
        #expect(migratedWorkspace.isUsingWorktree == false)

        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(migratedTask.executionRootPath == nil)
        #expect(migratedTask.executionEnvironmentSnapshotJSON == nil)

        let migratedRuns = try context.fetch(FetchDescriptor<TaskRun>())
        #expect(migratedRuns.allSatisfy { $0.executionEnvironmentSnapshotJSON == nil })
    }

    @MainActor
    @Test("Previous schema store migrates to empty pack profile workspace fields")
    func previousSchemaStoreMigratesToEmptyPackProfileWorkspaceFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-pack-profile-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV5.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV5.Workspace()
        oldWorkspace.name = "Legacy Profile"
        oldWorkspace.primaryPath = "/tmp/legacy-profile"
        oldContext.insert(oldWorkspace)
        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.enabledPackIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideValues.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrides.isEmpty)
    }

    @MainActor
    @Test("SchemaV9 store migrates directly to empty pack profile workspace fields")
    func v9StoreMigratesToEmptyPackProfileWorkspaceFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v9-pack-profile-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV9.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV9.Workspace()
        oldWorkspace.name = "Legacy V9 Profile"
        oldWorkspace.primaryPath = "/tmp/legacy-v9-profile"
        oldContext.insert(oldWorkspace)
        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.enabledPackIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideValues.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrides.isEmpty)
    }

    @MainActor
    @Test("SchemaV7 store (main's released 10-entity schema) migrates to V8 and gains the 5 Workspace App tables")
    func v7StoreMigratesToWorkspaceAppTables() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v7-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a store at main's V7 (10 core entities, NO Workspace App tables).
        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV7.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV7.Workspace()
        oldWorkspace.name = "Legacy V7"
        oldWorkspace.primaryPath = "/tmp/legacy-v7"
        oldContext.insert(oldWorkspace)
        let oldTask = ASTRASchemaV7.AgentTask()
        oldTask.title = "Legacy V7 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)
        let oldRun = ASTRASchemaV7.TaskRun()
        oldRun.task = oldTask
        oldContext.insert(oldRun)
        try oldContext.save()
        // Capture the id BEFORE tearing down the old container — the model instance is faulted/destroyed
        // once its container is released, so reading `oldWorkspace.id` afterward would crash.
        let oldWorkspaceID = oldWorkspace.id
        oldContainer = nil

        // Reopen at current through the migration plan: the V7 -> V8 lightweight stage must
        // create the 5 additive Workspace App tables while later stages preserve core rows.
        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext

        // Existing core rows survive the migration.
        #expect(try context.fetch(FetchDescriptor<Workspace>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<AgentTask>()).count == 1)

        // The 5 new tables exist (an empty fetch would THROW if the table were missing) and are writable.
        #expect(try context.fetch(FetchDescriptor<WorkspaceApp>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRun>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRunEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>()).isEmpty)

        let app = WorkspaceApp(
            workspaceID: oldWorkspaceID,
            logicalID: "legacy-v7-app",
            name: "Migrated App",
            manifestRelativePath: "apps/legacy-v7-app/manifest.json",
            appDirectoryRelativePath: "apps/legacy-v7-app",
            manifestDigest: "deadbeef"
        )
        context.insert(app)
        try context.save()
        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps.first?.name == "Migrated App")
    }

    @MainActor
    @Test("SchemaV7 store with a real non-host execution-environment payload survives migration to current byte-identical")
    func v7StoreCarriesNonHostExecutionEnvironmentPayloadThroughMigration() throws {
        // This exercises what the nil-only assertions elsewhere in this file don't: an actual
        // populated WorkspaceExecutionEnvironment (with credential projections) written as JSON
        // before the schema-version boundary, reopened under the current schema, decoded back,
        // and checked for exact equality/round-trip fidelity — not just "field is nil".
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v7-env-payload-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gcpADCHostPath = (root.path as NSString).appendingPathComponent(".config/gcloud")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: gcpADCHostPath),
            withIntermediateDirectories: true
        )

        let nonHostEnvironment = WorkspaceExecutionEnvironment(
            id: "image:legacy-v7-env",
            kind: .dockerImage,
            displayName: "Legacy V7 Environment",
            image: "astra/legacy:v7",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcpADCHostPath)
            ]
        )
        let encodedEnvironmentJSON = try #require(ExecutionEnvironmentStore.encode(nonHostEnvironment))

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV7.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let oldContext = try #require(oldContainer?.mainContext)

        let oldWorkspace = ASTRASchemaV7.Workspace()
        oldWorkspace.name = "Legacy V7 With Environment"
        oldWorkspace.primaryPath = "/tmp/legacy-v7-env"
        oldWorkspace.activeExecutionEnvironmentJSON = encodedEnvironmentJSON
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV7.AgentTask()
        oldTask.title = "Legacy V7 Task With Environment"
        oldTask.goal = "Do work in a container"
        oldTask.workspace = oldWorkspace
        oldTask.executionEnvironmentSnapshotJSON = encodedEnvironmentJSON
        oldContext.insert(oldTask)

        let oldRun = ASTRASchemaV7.TaskRun()
        oldRun.task = oldTask
        oldRun.executionEnvironmentSnapshotJSON = encodedEnvironmentJSON
        oldContext.insert(oldRun)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext

        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        let migratedRun = try #require(try context.fetch(FetchDescriptor<TaskRun>()).first)

        // The raw JSON string is byte-identical post-migration (lightweight migration must not
        // touch a field it doesn't declare a transform for).
        #expect(migratedWorkspace.activeExecutionEnvironmentJSON == encodedEnvironmentJSON)
        #expect(migratedTask.executionEnvironmentSnapshotJSON == encodedEnvironmentJSON)
        #expect(migratedRun.executionEnvironmentSnapshotJSON == encodedEnvironmentJSON)

        // And it decodes back to the exact same non-host environment, not `.host`.
        let decodedWorkspaceEnvironment = ExecutionEnvironmentStore.decode(migratedWorkspace.activeExecutionEnvironmentJSON)
        let decodedTaskEnvironment = ExecutionEnvironmentStore.decode(migratedTask.executionEnvironmentSnapshotJSON)
        let decodedRunEnvironment = ExecutionEnvironmentStore.decode(migratedRun.executionEnvironmentSnapshotJSON)

        #expect(!decodedWorkspaceEnvironment.isHost)
        #expect(decodedWorkspaceEnvironment == nonHostEnvironment)
        #expect(!decodedTaskEnvironment.isHost)
        #expect(decodedTaskEnvironment == nonHostEnvironment)
        #expect(!decodedRunEnvironment.isHost)
        #expect(decodedRunEnvironment == nonHostEnvironment)
        #expect(decodedTaskEnvironment.credentialProjections?.first?.kind == .gcpADC)
    }
}
