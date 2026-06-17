import Foundation
import Testing
@testable import ASTRA

@Suite("Task Sidebar Disclosure Store")
struct TaskSidebarDisclosureStoreTests {
    @Test("returns default expanded sidebar state until saved")
    func returnsDefaultExpandedStateUntilSaved() throws {
        let defaults = try freshDefaults()
        defer { TaskSidebarDisclosureStore.clear(defaults: defaults) }

        #expect(TaskSidebarDisclosureStore.load(defaults: defaults) == TaskSidebarDisclosureState())
    }

    @Test("persists section and workspace disclosure choices")
    func persistsDisclosureState() throws {
        let defaults = try freshDefaults()
        defer { TaskSidebarDisclosureStore.clear(defaults: defaults) }
        let collapsed = UUID()
        let expanded = UUID()
        let state = TaskSidebarDisclosureState(
            isPinnedExpanded: false,
            isWorkspacesExpanded: true,
            isSchedulesExpanded: false,
            collapsedWorkspaceIDs: [collapsed],
            expandedWorkspaceIDs: [expanded]
        )

        TaskSidebarDisclosureStore.save(state, defaults: defaults)

        #expect(TaskSidebarDisclosureStore.load(defaults: defaults) == state)
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "TaskSidebarDisclosureStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
