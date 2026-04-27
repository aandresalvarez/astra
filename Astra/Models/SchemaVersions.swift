import Foundation
import SwiftData

enum ASTRASchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            AgentTask.self,
            TaskRun.self,
            TaskEvent.self,
            Artifact.self,
            Skill.self,
            Connector.self,
            LocalTool.self,
            TaskTemplate.self,
            TaskSchedule.self
        ]
    }
}

enum ASTRAMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ASTRASchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
