import Foundation
import SwiftData

/// Frozen copies of the incompatible V15 written by the abandoned
/// external-operation branch (PR #328, `alvaro/durable-external-operation-monitoring`).
///
/// That branch reused version identifier 15.0.0 for a schema whose extra
/// entity is `TaskExternalOperation` instead of the canonical
/// `TaskTurnRequest`, and Dev builds from it ran long enough to write stores.
/// The canonical migration plan cannot open those stores: SwiftData resolves
/// the plan's 15.0.0 entry to the canonical checksum, so Core Data rejects
/// the store before any stage runs. Mirroring the colliding-V12 precedent,
/// each observed on-disk sub-shape is frozen here and recovered through its
/// own isolated plan.
///
/// The branch shipped the entity in two sub-shapes: `launchResourceKey` was
/// added mid-branch as an optional field, so stores exist both with and
/// without that column. Keep both declarations byte-for-byte aligned with the
/// historical model; never point them at live declarations.
public enum ASTRASchemaV15ExternalOperationModels {
    /// The final branch shape (22 stored attributes, with `launchResourceKey`).
    @Model
    public final class TaskExternalOperation {
        public var id: UUID
        public var taskID: UUID
        @Attribute(.unique) public var externalIdentity: String
        public var originatingRunID: UUID
        public var backendKindRaw: String
        public var backendJobID: String
        public var originatingContextRevision: String?
        public var executionStateRaw: String
        public var observationHealthRaw: String
        public var monitoringStateRaw: String
        public var nextCheckAt: Date?
        public var generation: Int
        public var leaseOwner: String?
        public var leaseExpiresAt: Date?
        public var lastObservedAt: Date?
        public var terminalObservedAt: Date?
        public var lastNotificationKey: String?
        public var lastWakeKey: String?
        public var consecutiveObservationFailures: Int
        public var launchResourceKey: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init() {
            id = UUID()
            taskID = UUID()
            externalIdentity = UUID().uuidString
            originatingRunID = UUID()
            backendKindRaw = ""
            backendJobID = ""
            originatingContextRevision = nil
            executionStateRaw = "registered"
            observationHealthRaw = "unknown"
            monitoringStateRaw = "active"
            nextCheckAt = nil
            generation = 0
            leaseOwner = nil
            leaseExpiresAt = nil
            lastObservedAt = nil
            terminalObservedAt = nil
            lastNotificationKey = nil
            lastWakeKey = nil
            consecutiveObservationFailures = 0
            launchResourceKey = nil
            createdAt = Date()
            updatedAt = Date()
        }
    }
}

/// See `ASTRASchemaV15ExternalOperationModels`: the pre-`launchResourceKey`
/// sub-shape (21 stored attributes) written by the branch's earlier builds.
public enum ASTRASchemaV15ExternalOperationInitialModels {
    @Model
    public final class TaskExternalOperation {
        public var id: UUID
        public var taskID: UUID
        @Attribute(.unique) public var externalIdentity: String
        public var originatingRunID: UUID
        public var backendKindRaw: String
        public var backendJobID: String
        public var originatingContextRevision: String?
        public var executionStateRaw: String
        public var observationHealthRaw: String
        public var monitoringStateRaw: String
        public var nextCheckAt: Date?
        public var generation: Int
        public var leaseOwner: String?
        public var leaseExpiresAt: Date?
        public var lastObservedAt: Date?
        public var terminalObservedAt: Date?
        public var lastNotificationKey: String?
        public var lastWakeKey: String?
        public var consecutiveObservationFailures: Int
        public var createdAt: Date
        public var updatedAt: Date

        public init() {
            id = UUID()
            taskID = UUID()
            externalIdentity = UUID().uuidString
            originatingRunID = UUID()
            backendKindRaw = ""
            backendJobID = ""
            originatingContextRevision = nil
            executionStateRaw = "registered"
            observationHealthRaw = "unknown"
            monitoringStateRaw = "active"
            nextCheckAt = nil
            generation = 0
            leaseOwner = nil
            leaseExpiresAt = nil
            lastObservedAt = nil
            terminalObservedAt = nil
            lastNotificationKey = nil
            lastWakeKey = nil
            consecutiveObservationFailures = 0
            createdAt = Date()
            updatedAt = Date()
        }
    }
}

/// The incompatible external-operation V15 (final sub-shape). Like the branch
/// it recovers, it composes the V14 core model list plus the frozen orphan
/// entity; those 18 core declarations were schema-identical across the
/// branch's whole life and remain so on main.
public enum ASTRASchemaV15ExternalOperation: VersionedSchema {
    public static var versionIdentifier = Schema.Version(15, 0, 0)

    public static var models: [any PersistentModel.Type] {
        ASTRASchemaV14.models + [ASTRASchemaV15ExternalOperationModels.TaskExternalOperation.self]
    }
}

/// The incompatible external-operation V15 (initial, pre-`launchResourceKey`
/// sub-shape).
public enum ASTRASchemaV15ExternalOperationInitial: VersionedSchema {
    public static var versionIdentifier = Schema.Version(15, 0, 0)

    public static var models: [any PersistentModel.Type] {
        ASTRASchemaV14.models + [ASTRASchemaV15ExternalOperationInitialModels.TaskExternalOperation.self]
    }
}

/// Isolated recovery plan for the final external-operation V15 sub-shape. The
/// lightweight stage to V16 creates the empty `TaskTurnRequest` table and
/// DROPS the orphan `TaskExternalOperation` rows by design: the feature never
/// shipped, no canonical schema carries the entity, and its rows are dead
/// control-plane monitoring state whose execution backend remains
/// authoritative. The migrator records the dropped row count.
public enum ASTRAExternalOperationV15MigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV15ExternalOperation.self, ASTRASchemaV16.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: ASTRASchemaV15ExternalOperation.self,
                toVersion: ASTRASchemaV16.self
            )
        ]
    }
}

/// Isolated recovery plan for the initial external-operation V15 sub-shape.
/// It cannot share a plan with the final sub-shape: both carry the same
/// 15.0.0 identifier with different model checksums.
public enum ASTRAExternalOperationInitialV15MigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV15ExternalOperationInitial.self, ASTRASchemaV16.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: ASTRASchemaV15ExternalOperationInitial.self,
                toVersion: ASTRASchemaV16.self
            )
        ]
    }
}
