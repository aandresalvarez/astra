import SwiftData

/// Frozen feedback-only V12 that shipped before runtime-selection state joined
/// the same schema number on another branch. Its common entities intentionally
/// reuse the exact V11 model definitions that reached disk; changing them would
/// make Core Data reject existing user stores before migration can run.
public enum ASTRASchemaV12FeedbackOnly: VersionedSchema {
    public static var versionIdentifier = Schema.Version(12, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ASTRASchemaV11.Workspace.self,
            ASTRASchemaV11.AgentTask.self,
            ASTRASchemaV11.TaskRun.self,
            ASTRASchemaV11.TaskEvent.self,
            ASTRASchemaV11.Artifact.self,
            ASTRASchemaV11.Skill.self,
            ASTRASchemaV11.Connector.self,
            ASTRASchemaV11.LocalTool.self,
            ASTRASchemaV11.TaskTemplate.self,
            ASTRASchemaV11.TaskSchedule.self,
            ASTRASchemaV11.WorkspaceApp.self,
            ASTRASchemaV11.WorkspaceAppRun.self,
            ASTRASchemaV11.WorkspaceAppRunEvent.self,
            ASTRASchemaV11.WorkspaceAppDependencyBinding.self,
            ASTRASchemaV11.WorkspaceAppAutomationState.self,
            ASTRASchemaV11.GoogleOAuthAccountProfile.self,
            ASTRASchemaV12Models.FeedbackReport.self
        ]
    }
}
