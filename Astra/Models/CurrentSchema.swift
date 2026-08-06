import SwiftData

/// V14 moves the remembered per-task canvas selection out of a global
/// UserDefaults JSON dictionary and onto AgentTask. The optional scalar makes
/// this an additive lightweight migration and ties deletion to the task row.
public enum ASTRASchemaV14: VersionedSchema {
    public static var versionIdentifier = Schema.Version(14, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ASTRASchemaV14Models.Workspace.self,
            ASTRASchemaV14Models.AgentTask.self,
            ASTRASchemaV14Models.TaskRun.self,
            ASTRASchemaV14Models.TaskEvent.self,
            ASTRASchemaV14Models.Artifact.self,
            ASTRASchemaV14Models.Skill.self,
            ASTRASchemaV14Models.Connector.self,
            ASTRASchemaV14Models.LocalTool.self,
            ASTRASchemaV14Models.TaskTemplate.self,
            ASTRASchemaV14Models.TaskSchedule.self,
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
            ASTRASchemaV14Models.Workspace.self,
            ASTRASchemaV14Models.AgentTask.self,
            ASTRASchemaV14Models.TaskRun.self,
            ASTRASchemaV14Models.TaskEvent.self,
            ASTRASchemaV14Models.Artifact.self,
            ASTRASchemaV14Models.Skill.self,
            ASTRASchemaV14Models.Connector.self,
            ASTRASchemaV14Models.LocalTool.self,
            ASTRASchemaV14Models.TaskTemplate.self,
            ASTRASchemaV14Models.TaskSchedule.self,
            WorkspaceApp.self,
            WorkspaceAppRun.self,
            WorkspaceAppRunEvent.self,
            WorkspaceAppDependencyBinding.self,
            WorkspaceAppAutomationState.self,
            GoogleOAuthAccountProfile.self,
            FeedbackReport.self,
            PersistentStoreMigrationRecord.self,
            ASTRASchemaV15Models.TaskTurnRequest.self
        ]
    }
}

/// V16 generalizes durable turn admission into one execution-request contract
/// shared by initial runs, follow-ups, retries, schedules, and plan steps.
public enum ASTRASchemaV16: VersionedSchema {
    public static var versionIdentifier = Schema.Version(16, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ASTRASchemaV14Models.Workspace.self,
            ASTRASchemaV14Models.AgentTask.self,
            ASTRASchemaV14Models.TaskRun.self,
            ASTRASchemaV14Models.TaskEvent.self,
            ASTRASchemaV14Models.Artifact.self,
            ASTRASchemaV14Models.Skill.self,
            ASTRASchemaV14Models.Connector.self,
            ASTRASchemaV14Models.LocalTool.self,
            ASTRASchemaV14Models.TaskTemplate.self,
            ASTRASchemaV14Models.TaskSchedule.self,
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

/// V17 persists whether a run's output carries run-protocol markers, so plan
/// recovery can select candidate runs from a 1-byte column instead of
/// LIKE-scanning every run's output blob. The flag is optional: `nil` marks a
/// pre-V17 row that has never been scanned, which keeps the additive stage
/// lightweight and keeps recovery correct before the backfill lands.
public enum ASTRASchemaV17: VersionedSchema {
    public static var versionIdentifier = Schema.Version(17, 0, 0)

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
    public static let currentVersion = 17

    public static var current: Schema {
        Schema(versionedSchema: ASTRASchemaV17.self)
    }
}
