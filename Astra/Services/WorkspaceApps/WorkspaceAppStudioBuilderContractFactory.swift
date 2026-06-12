import Foundation

enum WorkspaceAppStudioBuilderContractFactory {
    static func contract(for context: WorkspaceAppStudioContext) -> WorkspaceAppStudioBuilderContract {
        WorkspaceAppStudioBuilderContract(sections: [
            .init(title: "User request", body: emptyFallback(context.prompt)),
            .init(title: "Workspace", body: workspaceBody(context.workspace)),
            .init(title: "Capabilities", body: capabilitiesBody(context.capabilities)),
            .init(title: "Recent tasks", body: tasksBody(context.tasks)),
            .init(title: "Artifacts", body: artifactsBody(context.artifacts)),
            .init(title: "Existing app manifest", body: emptyFallback(context.existingAppManifest ?? ""))
        ])
    }

    private static func workspaceBody(_ workspace: WorkspaceAppStudioWorkspaceContext) -> String {
        [
            "Name: \(workspace.name)",
            "Primary path: \(workspace.primaryPath)",
            "Working path: \(workspace.workingPath)",
            "Instructions: \(emptyFallback(workspace.instructions))"
        ].joined(separator: "\n")
    }

    private static func capabilitiesBody(_ capabilities: [WorkspaceAppStudioCapabilityContext]) -> String {
        guard !capabilities.isEmpty else {
            return "No enabled workspace capabilities were provided."
        }

        return capabilities.map { capability in
            var lines = [
                "- \(capability.name) (\(capability.id))",
                "  Readiness: \(capability.readiness)",
                "  Risk: \(capability.governance.riskLevel)",
                "  Data access: \(joined(capability.governance.dataAccess))",
                "  Effects: \(joined(capability.governance.externalEffects))",
                "  Contents: \(emptyFallback(capability.contentSummary))"
            ]
            if !capability.messages.isEmpty {
                lines.append("  Needs attention: \(capability.messages.joined(separator: "; "))")
            }
            if !capability.connectors.isEmpty {
                lines.append("  Connectors: \(joined(capability.connectors))")
            }
            if !capability.tools.isEmpty {
                lines.append("  Tools: \(joined(capability.tools))")
            }
            if !capability.skills.isEmpty {
                lines.append("  Skills: \(joined(capability.skills))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func tasksBody(_ tasks: [WorkspaceAppStudioTaskContext]) -> String {
        guard !tasks.isEmpty else {
            return "No recent workspace tasks were included."
        }

        return tasks.map { task in
            var lines = [
                "- \(task.title) [\(task.status)]",
                "  Goal: \(emptyFallback(task.goal))"
            ]
            if !task.inputs.isEmpty {
                lines.append("  Inputs: \(task.inputs.joined(separator: " | "))")
            }
            if !task.eventExcerpts.isEmpty {
                let eventLines = task.eventExcerpts.map { event in
                    "\(event.type): \(event.payload)"
                }
                lines.append("  Recent events: \(eventLines.joined(separator: " | "))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func artifactsBody(_ artifacts: [WorkspaceAppStudioArtifactContext]) -> String {
        guard !artifacts.isEmpty else {
            return "No workspace artifacts were included."
        }

        return artifacts.map { artifact in
            var line = "- \(artifact.fileName) (\(artifact.kind)) at \(artifact.path)"
            if let taskTitle = artifact.taskTitle, !taskTitle.isEmpty {
                line += " from \(taskTitle)"
            }
            if let excerpt = artifact.excerpt, !excerpt.isEmpty {
                line += "\n  Excerpt: \(excerpt)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func joined(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private static func emptyFallback(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : value
    }
}
