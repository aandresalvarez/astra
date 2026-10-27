import Testing
import Foundation
@testable import ASTRA

@Suite("Rail Disclosure Store")
struct RailDisclosureStoreTests {
    private func freshWorkspaceID() -> String {
        // Unique per test run so assertions never collide with real UserDefaults
        // state or with each other.
        "test-\(UUID().uuidString)"
    }

    @Test("returns the supplied default until the user touches a toggle")
    func returnsDefaultUntilTouched() {
        let id = freshWorkspaceID()
        defer { RailDisclosureStore.clear(id) }
        #expect(RailDisclosureStore.bool(id, .contextExpanded, default: false) == false)
        #expect(RailDisclosureStore.bool(id, .environmentExpanded, default: true) == true)
    }

    @Test("persists a toggle and reads it back")
    func persistsAndReadsBack() {
        let id = freshWorkspaceID()
        defer { RailDisclosureStore.clear(id) }
        RailDisclosureStore.setBool(true, id, .capabilitiesExpanded)
        #expect(RailDisclosureStore.bool(id, .capabilitiesExpanded, default: false) == true)

        RailDisclosureStore.setBool(false, id, .capabilitiesExpanded)
        // An explicit false must win over a true default — proving presence is
        // distinguished from absence.
        #expect(RailDisclosureStore.bool(id, .capabilitiesExpanded, default: true) == false)
    }

    @Test("one workspace's layout does not leak into another")
    func isolatesPerWorkspace() {
        let a = freshWorkspaceID()
        let b = freshWorkspaceID()
        defer { RailDisclosureStore.clear(a); RailDisclosureStore.clear(b) }
        RailDisclosureStore.setBool(true, a, .environmentExpanded)
        #expect(RailDisclosureStore.bool(a, .environmentExpanded, default: false) == true)
        #expect(RailDisclosureStore.bool(b, .environmentExpanded, default: false) == false)
    }

    @Test("clearing a workspace also drops the toggles the v1 rail persisted")
    func clearDropsRetiredToggles() {
        let id = freshWorkspaceID()
        let retiredKey = "workspaceRail.disclosure.\(id).readyCapabilitiesExpanded"
        UserDefaults.standard.set(true, forKey: retiredKey)
        RailDisclosureStore.setBool(false, id, .capabilitiesExpanded)

        RailDisclosureStore.clear(id)

        #expect(UserDefaults.standard.object(forKey: retiredKey) == nil)
        #expect(RailDisclosureStore.bool(id, .capabilitiesExpanded, default: true) == true)
        #expect(RailDisclosureStore.retiredToggleRawValues.contains("readyCapabilitiesExpanded"))
        #expect(RailDisclosureStore.retiredToggleRawValues.contains("repositoryShowsDetails"))
    }
}
