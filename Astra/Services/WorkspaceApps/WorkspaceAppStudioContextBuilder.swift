import Foundation

enum WorkspaceAppStudioContextBuilder {
    static func build(_ request: WorkspaceAppStudioContextRequest) -> WorkspaceAppStudioContext {
        let excerptLimit = max(0, request.excerptCharacterLimit)
        let prompt = redactAndLimit(request.userPrompt, limit: excerptLimit)
        let workspace = workspaceContext(from: request.workspace, excerptLimit: excerptLimit)
        let capabilities = capabilityContexts(from: request.capabilityStates)
        let tasks = taskContexts(
            from: request.workspace.tasks,
            taskLimit: request.recentTaskLimit,
            eventLimit: request.eventLimitPerTask,
            excerptLimit: excerptLimit
        )
        let artifacts = artifactContexts(
            from: tasks,
            workspaceTasks: request.workspace.tasks,
            limit: request.artifactLimit,
            excerptLimit: excerptLimit
        )
        let manifestExcerptLimit = doubledLimit(excerptLimit)
        let existingManifest = request.existingAppManifest.map {
            redactAndLimit($0, limit: manifestExcerptLimit)
        }
        let context = WorkspaceAppStudioContext(
            prompt: prompt,
            workspace: workspace,
            capabilities: capabilities,
            tasks: tasks,
            artifacts: artifacts,
            existingAppManifest: existingManifest,
            builderContract: WorkspaceAppStudioBuilderContract(sections: [])
        )

        return WorkspaceAppStudioContext(
            prompt: context.prompt,
            workspace: context.workspace,
            capabilities: context.capabilities,
            tasks: context.tasks,
            artifacts: context.artifacts,
            existingAppManifest: context.existingAppManifest,
            builderContract: WorkspaceAppStudioBuilderContractFactory.contract(for: context)
        )
    }

    private static func workspaceContext(
        from workspace: Workspace,
        excerptLimit: Int
    ) -> WorkspaceAppStudioWorkspaceContext {
        WorkspaceAppStudioWorkspaceContext(
            id: workspace.id,
            name: redactAndLimit(workspace.name, limit: excerptLimit),
            primaryPath: workspace.primaryPath,
            workingPath: workspace.resolvedWorkingPath,
            instructions: redactAndLimit(workspace.instructions, limit: excerptLimit)
        )
    }

    private static func capabilityContexts(
        from states: [CapabilityPackageState]
    ) -> [WorkspaceAppStudioCapabilityContext] {
        states
            .filter(\.isEnabled)
            .map(capabilityContext)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private static func capabilityContext(
        from state: CapabilityPackageState
    ) -> WorkspaceAppStudioCapabilityContext {
        let readiness = state.readiness
        let messages = readiness.level == .ready
            ? []
            : readiness.messages.map(WorkspaceAppStudioContextRedactor.redact)

        return WorkspaceAppStudioCapabilityContext(
            id: state.package.id,
            name: WorkspaceAppStudioContextRedactor.redact(state.package.name),
            description: WorkspaceAppStudioContextRedactor.redact(state.package.description),
            readiness: readinessLabel(readiness.level),
            messages: messages,
            contentSummary: state.package.contentSummary,
            governance: WorkspaceAppStudioCapabilityGovernanceContext(
                riskLevel: state.package.governance.riskLevel.rawValue,
                dataAccess: state.package.governance.dataAccess.map(\.rawValue),
                externalEffects: state.package.governance.externalEffects.map(\.rawValue)
            ),
            skills: redactedNames(state.linkedSkills.map(\.name)),
            connectors: redactedNames(state.linkedConnectors.map(\.name)),
            tools: redactedNames(state.linkedTools.map(\.name))
        )
    }

    private static func taskContexts(
        from tasks: [AgentTask],
        taskLimit: Int,
        eventLimit: Int,
        excerptLimit: Int
    ) -> [WorkspaceAppStudioTaskContext] {
        sortedTasks(tasks)
            .prefix(max(0, taskLimit))
            .map { task in
                WorkspaceAppStudioTaskContext(
                    id: task.id,
                    title: redactAndLimit(task.title, limit: excerptLimit),
                    goal: redactAndLimit(task.goal, limit: excerptLimit),
                    inputs: task.inputs.map { redactAndLimit($0, limit: excerptLimit) },
                    status: task.status.rawValue,
                    updatedAt: task.updatedAt,
                    eventExcerpts: eventExcerpts(
                        from: task.events,
                        limit: eventLimit,
                        excerptLimit: excerptLimit
                    )
                )
            }
    }

    private static func eventExcerpts(
        from events: [TaskEvent],
        limit: Int,
        excerptLimit: Int
    ) -> [WorkspaceAppStudioEventExcerpt] {
        events
            .filter { event in
                event.hasType(TaskEventTypes.Conversation.userMessage) ||
                    event.hasType(TaskEventTypes.Conversation.agentResponse)
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.type < rhs.type
            }
            .prefix(max(0, limit))
            .map { event in
                WorkspaceAppStudioEventExcerpt(
                    type: event.type,
                    payload: redactAndLimit(event.payload, limit: excerptLimit),
                    timestamp: event.timestamp
                )
            }
    }

    private static func artifactContexts(
        from selectedTasks: [WorkspaceAppStudioTaskContext],
        workspaceTasks: [AgentTask],
        limit: Int,
        excerptLimit: Int
    ) -> [WorkspaceAppStudioArtifactContext] {
        let selectedTaskIDs = Set(selectedTasks.map(\.id))
        return workspaceTasks
            .filter { selectedTaskIDs.contains($0.id) }
            .flatMap { task in
                task.artifacts.map { artifact in
                    artifactContext(from: artifact, task: task, excerptLimit: excerptLimit)
                }
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func artifactContext(
        from artifact: Artifact,
        task: AgentTask,
        excerptLimit: Int
    ) -> WorkspaceAppStudioArtifactContext {
        WorkspaceAppStudioArtifactContext(
            id: artifact.id,
            taskID: task.id,
            taskTitle: redactAndLimit(task.title, limit: excerptLimit),
            path: artifact.path,
            fileName: URL(fileURLWithPath: artifact.path).lastPathComponent,
            kind: artifact.kind.rawValue,
            excerpt: artifact.content.map { redactAndLimit($0, limit: excerptLimit) },
            createdAt: artifact.createdAt
        )
    }

    private static func sortedTasks(_ tasks: [AgentTask]) -> [AgentTask] {
        tasks.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func readinessLabel(_ level: CapabilityReadinessLevel) -> String {
        switch level {
        case .inactive:
            return "inactive"
        case .ready:
            return "ready"
        case .needsAttention:
            return "needsAttention"
        }
    }

    private static func redactedNames(_ names: [String]) -> [String] {
        names.map(WorkspaceAppStudioContextRedactor.redact)
    }

    private static func doubledLimit(_ limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        guard limit <= Int.max / 2 else { return Int.max }
        return limit * 2
    }

    private static func redactAndLimit(_ rawValue: String, limit: Int) -> String {
        let redacted = WorkspaceAppStudioContextRedactor.redact(rawValue)
        guard limit > 0, redacted.count > limit else {
            return redacted
        }
        return String(redacted.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
