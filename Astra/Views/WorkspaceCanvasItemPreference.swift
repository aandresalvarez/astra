import Foundation
import SwiftData
import ASTRAPersistence
import ASTRACore
import ASTRAModels

/// Pure conversion and restoration policy for task-owned canvas preferences.
/// Durable storage lives on `AgentTask`; transient visibility lives in
/// `RightPanelPresentationModel`.
struct WorkspaceCanvasItemPreference: Equatable {
    static func rawValue(for item: WorkspaceCanvasItem?) -> String? {
        item?.rawValue
    }

    static func item(for rawValue: String?) -> WorkspaceCanvasItem? {
        rawValue.flatMap(WorkspaceCanvasItem.init(rawValue:))
    }

    static func shouldRestoreRememberedItem(
        activeItem: WorkspaceCanvasItem?,
        isRightRailVisible: Bool,
        rememberedItem: WorkspaceCanvasItem?,
        canPresentRememberedItem: Bool
    ) -> Bool {
        activeItem == nil
            && !isRightRailVisible
            && rememberedItem != nil
            && canPresentRememberedItem
    }
}

enum WorkspaceCanvasPreferenceIntent: Equatable {
    case explicitUserChoice
    case transient
}

/// The only production writer for a task's remembered canvas item.
///
/// The injected persistence seam makes save failures deterministic in tests.
/// A failed save restores only this service's field instead of rolling back the
/// whole context and potentially discarding unrelated user work.
@MainActor
struct WorkspaceCanvasItemPreferenceService {
    typealias Persistence = @MainActor (AgentTask, ModelContext) throws -> Void

    private let modelContext: ModelContext
    private let persist: Persistence

    init(modelContext: ModelContext, persist: Persistence? = nil) {
        self.modelContext = modelContext
        self.persist = persist ?? { task, context in
            let workspace = task.workspace
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                workspace: workspace,
                modelContext: context,
                taskID: task.id,
                auditFields: ["operation": "remember_workspace_canvas_item"]
            )
            if let workspace {
                WorkspacePersistenceCoordinator.scheduleAutoExport(
                    workspace: workspace,
                    modelContext: context
                )
            }
        }
    }

    func rememberedItem(for task: AgentTask?) -> WorkspaceCanvasItem? {
        WorkspaceCanvasItemPreference.item(for: task?.rememberedWorkspaceCanvasItemRawValue)
    }

    @discardableResult
    func apply(
        _ intent: WorkspaceCanvasPreferenceIntent,
        item: WorkspaceCanvasItem?,
        for task: AgentTask?
    ) -> Bool {
        guard intent == .explicitUserChoice else { return true }
        return setRememberedItem(item, for: task)
    }

    @discardableResult
    func setRememberedItem(_ item: WorkspaceCanvasItem?, for task: AgentTask?) -> Bool {
        guard let task else { return false }
        let nextRawValue = WorkspaceCanvasItemPreference.rawValue(for: item)
        let previousRawValue = task.rememberedWorkspaceCanvasItemRawValue
        guard previousRawValue != nextRawValue else { return true }

        task.rememberedWorkspaceCanvasItemRawValue = nextRawValue
        do {
            try persist(task, modelContext)
            return true
        } catch {
            task.rememberedWorkspaceCanvasItemRawValue = previousRawValue
            AppLogger.audit(.runtimePersistenceSummary, category: "Persistence", taskID: task.id, fields: [
                "operation": "remember_workspace_canvas_item",
                "result": "rolled_back",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
    }
}

struct GeneratedHTMLDiscoveryState: Equatable {
    let preferredPath: String
    let signature: String

    static let empty = GeneratedHTMLDiscoveryState(preferredPath: "", signature: "")

    static func discovered(preferredPath: String, taskID: UUID) -> GeneratedHTMLDiscoveryState {
        GeneratedHTMLDiscoveryState(
            preferredPath: preferredPath,
            signature: TaskGeneratedFiles.htmlPreviewSignature(for: preferredPath, taskID: taskID)
        )
    }

    func shouldApplyDiscovery(preferredPath: String, taskID: UUID) -> Bool {
        signature != TaskGeneratedFiles.htmlPreviewSignature(for: preferredPath, taskID: taskID)
    }
}
