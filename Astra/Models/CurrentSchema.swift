import SwiftData

/// V14 moves the remembered per-task canvas selection out of a global
/// UserDefaults JSON dictionary and onto AgentTask. The optional scalar makes
/// this an additive lightweight migration and ties deletion to the task row.
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

/// V15 adds durable turn-admission requests. The append-only user message is
/// persisted before worker/resource admission so it cannot disappear while
/// waiting for a shared workspace lock.
public enum ASTRASchemaV15: VersionedSchema {
    public static var versionIdentifier = Schema.Version(15, 0, 0)

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
            PersistentStoreMigrationRecord.self,
            TaskTurnRequest.self
        ]
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
