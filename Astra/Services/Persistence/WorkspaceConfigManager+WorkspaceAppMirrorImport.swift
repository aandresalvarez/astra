import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

extension WorkspaceConfigManager {
    public static func replaceWorkspaceAppMirrorRows(for workspaceID: UUID, modelContext: ModelContext) {
        let automationDescriptor = FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate { $0.workspaceID == workspaceID }
        )
        for state in (try? modelContext.fetch(automationDescriptor)) ?? [] {
            modelContext.delete(state)
        }

        let bindingDescriptor = FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate { $0.workspaceID == workspaceID }
        )
        for binding in (try? modelContext.fetch(bindingDescriptor)) ?? [] {
            modelContext.delete(binding)
        }

        let eventDescriptor = FetchDescriptor<WorkspaceAppRunEvent>(
            predicate: #Predicate { $0.workspaceID == workspaceID }
        )
        for event in (try? modelContext.fetch(eventDescriptor)) ?? [] {
            modelContext.delete(event)
        }

        let runDescriptor = FetchDescriptor<WorkspaceAppRun>(
            predicate: #Predicate { $0.workspaceID == workspaceID }
        )
        for run in (try? modelContext.fetch(runDescriptor)) ?? [] {
            modelContext.delete(run)
        }

        let appDescriptor = FetchDescriptor<WorkspaceApp>(
            predicate: #Predicate { $0.workspaceID == workspaceID }
        )
        for app in (try? modelContext.fetch(appDescriptor)) ?? [] {
            modelContext.delete(app)
        }
    }
}
