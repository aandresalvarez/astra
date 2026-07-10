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

    @Test("persists section disclosure and the single open workspace drawer")
    func persistsDisclosureState() throws {
        let defaults = try freshDefaults()
        defer { TaskSidebarDisclosureStore.clear(defaults: defaults) }
        let state = TaskSidebarDisclosureState(
            isPinnedExpanded: false,
            isWorkspacesExpanded: true,
            isSchedulesExpanded: false,
            openWorkspaceID: UUID()
        )

        TaskSidebarDisclosureStore.save(state, defaults: defaults)

        #expect(TaskSidebarDisclosureStore.load(defaults: defaults) == state)
    }

    @Test("saving a nil open drawer clears the persisted ID")
    func persistsClosedAccordion() throws {
        let defaults = try freshDefaults()
        defer { TaskSidebarDisclosureStore.clear(defaults: defaults) }

        TaskSidebarDisclosureStore.save(
            TaskSidebarDisclosureState(openWorkspaceID: UUID()),
            defaults: defaults
        )
        TaskSidebarDisclosureStore.save(
            TaskSidebarDisclosureState(openWorkspaceID: nil),
            defaults: defaults
        )

        #expect(TaskSidebarDisclosureStore.load(defaults: defaults).openWorkspaceID == nil)
    }

    @Test("saving purges the pre-accordion workspace ID sets")
    func savePurgesLegacyWorkspaceSets() throws {
        let defaults = try freshDefaults()
        defer { TaskSidebarDisclosureStore.clear(defaults: defaults) }
        defaults.set([UUID().uuidString], forKey: "taskSidebar.collapsedWorkspaceIDs")
        defaults.set([UUID().uuidString], forKey: "taskSidebar.expandedWorkspaceIDs")

        TaskSidebarDisclosureStore.save(TaskSidebarDisclosureState(), defaults: defaults)

        #expect(defaults.object(forKey: "taskSidebar.collapsedWorkspaceIDs") == nil)
        #expect(defaults.object(forKey: "taskSidebar.expandedWorkspaceIDs") == nil)
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "TaskSidebarDisclosureStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
