import SwiftUI
import SwiftData
import ASTRAModels

/// Sonoma's SwiftData save notifications are not a reliable membership signal.
/// Keep its existing bounded Query subscription; newer systems use the store's
/// save/model observers and never instantiate this query.
struct SidebarTaskLegacyChangeSignal: View {
    let store: SidebarTaskStore

    var body: some View {
        if #available(macOS 15, *) {
            EmptyView()
        } else {
            LegacyTaskQuerySignal(store: store)
        }
    }
}

private struct LegacyTaskQuerySignal: View {
    @Query(descriptor()) private var taskChangeSignal: [AgentTask]
    @Environment(\.modelContext) private var modelContext
    let store: SidebarTaskStore

    private static func descriptor() -> FetchDescriptor<AgentTask> {
        var descriptor = FetchDescriptor<AgentTask>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        let _ = taskChangeSignal.count
        store.noteChanged(context: modelContext)
        return Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
