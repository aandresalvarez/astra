import SwiftData

public enum ASTRAMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            ASTRASchemaV1.self,
            ASTRASchemaV2.self,
            ASTRASchemaV3.self,
            ASTRASchemaV4.self,
            ASTRASchemaV5.self,
            ASTRASchemaV6.self,
            ASTRASchemaV7.self,
            ASTRASchemaV8.self,
            ASTRASchemaV9.self,
            ASTRASchemaV10.self,
            ASTRASchemaV11.self,
            ASTRASchemaV12.self,
            ASTRASchemaV13.self,
            ASTRASchemaV14.self,
            ASTRASchemaV15.self,
            ASTRASchemaV16.self,
            ASTRASchemaV17.self
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ASTRASchemaV1.self, toVersion: ASTRASchemaV2.self),
            .lightweight(fromVersion: ASTRASchemaV2.self, toVersion: ASTRASchemaV3.self),
            .lightweight(fromVersion: ASTRASchemaV3.self, toVersion: ASTRASchemaV4.self),
            .lightweight(fromVersion: ASTRASchemaV4.self, toVersion: ASTRASchemaV5.self),
            .lightweight(fromVersion: ASTRASchemaV5.self, toVersion: ASTRASchemaV6.self),
            .lightweight(fromVersion: ASTRASchemaV6.self, toVersion: ASTRASchemaV7.self),
            .lightweight(fromVersion: ASTRASchemaV7.self, toVersion: ASTRASchemaV8.self),
            .lightweight(fromVersion: ASTRASchemaV8.self, toVersion: ASTRASchemaV9.self),
            .lightweight(fromVersion: ASTRASchemaV9.self, toVersion: ASTRASchemaV10.self),
            .lightweight(fromVersion: ASTRASchemaV10.self, toVersion: ASTRASchemaV11.self),
            .lightweight(fromVersion: ASTRASchemaV11.self, toVersion: ASTRASchemaV12.self),
            .lightweight(fromVersion: ASTRASchemaV12.self, toVersion: ASTRASchemaV13.self),
            .lightweight(fromVersion: ASTRASchemaV13.self, toVersion: ASTRASchemaV14.self),
            .lightweight(fromVersion: ASTRASchemaV14.self, toVersion: ASTRASchemaV15.self),
            .lightweight(fromVersion: ASTRASchemaV15.self, toVersion: ASTRASchemaV16.self),
            .lightweight(fromVersion: ASTRASchemaV16.self, toVersion: ASTRASchemaV17.self)
        ]
    }
}

/// Dedicated plan for the short-lived runtime-selection-only V12. Keeping it
/// separate avoids placing two different 12.0.0 shapes in the normal plan.
public enum ASTRAOrphanedV12MigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV12RuntimeOnly.self, ASTRASchemaV13.self, ASTRASchemaV14.self, ASTRASchemaV15.self, ASTRASchemaV16.self, ASTRASchemaV17.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ASTRASchemaV12RuntimeOnly.self, toVersion: ASTRASchemaV13.self),
            .lightweight(fromVersion: ASTRASchemaV13.self, toVersion: ASTRASchemaV14.self),
            .lightweight(fromVersion: ASTRASchemaV14.self, toVersion: ASTRASchemaV15.self),
            .lightweight(fromVersion: ASTRASchemaV15.self, toVersion: ASTRASchemaV16.self),
            .lightweight(fromVersion: ASTRASchemaV16.self, toVersion: ASTRASchemaV17.self)
        ]
    }
}

/// Dedicated plan for the feedback-only V12 collision. It cannot share the
/// normal plan with another schema carrying the same 12.0.0 identifier.
public enum ASTRAFeedbackOnlyV12MigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV12FeedbackOnly.self, ASTRASchemaV13.self, ASTRASchemaV14.self, ASTRASchemaV15.self, ASTRASchemaV16.self, ASTRASchemaV17.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ASTRASchemaV12FeedbackOnly.self, toVersion: ASTRASchemaV13.self),
            .lightweight(fromVersion: ASTRASchemaV13.self, toVersion: ASTRASchemaV14.self),
            .lightweight(fromVersion: ASTRASchemaV14.self, toVersion: ASTRASchemaV15.self),
            .lightweight(fromVersion: ASTRASchemaV15.self, toVersion: ASTRASchemaV16.self),
            .lightweight(fromVersion: ASTRASchemaV16.self, toVersion: ASTRASchemaV17.self)
        ]
    }
}
