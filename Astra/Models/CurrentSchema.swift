import SwiftData

/// Frozen V14 model list. TaskExternalOperation is intentionally absent, and
/// its task ownership is represented by a scalar taskID so V14's live
/// AgentTask declaration remains schema-identical when V15 is introduced.
public enum ASTRASchemaV14: VersionedSchema {
    public static var versionIdentifier = Schema.Version(14, 0, 0)

    public static var models: [any PersistentModel.Type] {
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
            TaskSchedule.self,
            WorkspaceApp.self,
            WorkspaceAppRun.self,
            WorkspaceAppRunEvent.self,
            WorkspaceAppDependencyBinding.self,
            WorkspaceAppAutomationState.self,
            GoogleOAuthAccountProfile.self,
            FeedbackReport.self,
            PersistentStoreMigrationRecord.self
        ]
    }
}

/// V15 adds the task-owned external-operation control-plane entity without
/// changing the historical AgentTask entity shape.
public enum ASTRASchemaV15: VersionedSchema {
    public static var versionIdentifier = Schema.Version(15, 0, 0)

    public static var models: [any PersistentModel.Type] {
        ASTRASchemaV14.models + [TaskExternalOperation.self]
    }
}

public enum ASTRASchema {
    /// The newest durable store schema this binary can read and write.
    /// Keep startup compatibility checks derived from this single owner.
    public static let currentVersion = 15

    public static var current: Schema {
        Schema(versionedSchema: ASTRASchemaV15.self)
    }
}
