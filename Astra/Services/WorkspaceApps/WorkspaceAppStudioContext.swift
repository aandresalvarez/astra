import Foundation

struct WorkspaceAppStudioContextRequest {
    var userPrompt: String
    var workspace: Workspace
    var capabilityStates: [CapabilityPackageState]
    var existingAppManifest: String?
    var recentTaskLimit: Int
    var eventLimitPerTask: Int
    var artifactLimit: Int
    var excerptCharacterLimit: Int

    init(
        userPrompt: String,
        workspace: Workspace,
        capabilityStates: [CapabilityPackageState] = [],
        existingAppManifest: String? = nil,
        recentTaskLimit: Int = 4,
        eventLimitPerTask: Int = 3,
        artifactLimit: Int = 6,
        excerptCharacterLimit: Int = 600
    ) {
        self.userPrompt = userPrompt
        self.workspace = workspace
        self.capabilityStates = capabilityStates
        self.existingAppManifest = existingAppManifest
        self.recentTaskLimit = recentTaskLimit
        self.eventLimitPerTask = eventLimitPerTask
        self.artifactLimit = artifactLimit
        self.excerptCharacterLimit = excerptCharacterLimit
    }
}

struct WorkspaceAppStudioContext: Equatable {
    var prompt: String
    var workspace: WorkspaceAppStudioWorkspaceContext
    var capabilities: [WorkspaceAppStudioCapabilityContext]
    var tasks: [WorkspaceAppStudioTaskContext]
    var artifacts: [WorkspaceAppStudioArtifactContext]
    var existingAppManifest: String?
    var builderContract: WorkspaceAppStudioBuilderContract
}

struct WorkspaceAppStudioWorkspaceContext: Equatable {
    var id: UUID
    var name: String
    var primaryPath: String
    var workingPath: String
    var instructions: String
}

struct WorkspaceAppStudioCapabilityContext: Equatable {
    var id: String
    var name: String
    var description: String
    var readiness: String
    var messages: [String]
    var contentSummary: String
    var governance: WorkspaceAppStudioCapabilityGovernanceContext
    var skills: [String]
    var connectors: [String]
    var tools: [String]
}

struct WorkspaceAppStudioCapabilityGovernanceContext: Equatable {
    var riskLevel: String
    var dataAccess: [String]
    var externalEffects: [String]
}

struct WorkspaceAppStudioTaskContext: Equatable {
    var id: UUID
    var title: String
    var goal: String
    var inputs: [String]
    var status: String
    var updatedAt: Date
    var eventExcerpts: [WorkspaceAppStudioEventExcerpt]
}

struct WorkspaceAppStudioEventExcerpt: Equatable {
    var type: String
    var payload: String
    var timestamp: Date
}

struct WorkspaceAppStudioArtifactContext: Equatable {
    var id: UUID
    var taskID: UUID?
    var taskTitle: String?
    var path: String
    var fileName: String
    var kind: String
    var excerpt: String?
    var createdAt: Date
}

struct WorkspaceAppStudioBuilderContract: Equatable {
    struct Section: Equatable {
        var title: String
        var body: String
    }

    var sections: [Section]

    var renderedPrompt: String {
        sections
            .map { section in
                """
                ## \(section.title)
                \(section.body)
                """
            }
            .joined(separator: "\n\n")
    }
}
