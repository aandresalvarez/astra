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
        #expect(RailDisclosureStore.bool(id, .configuredSetupExpanded, default: false) == false)
        #expect(RailDisclosureStore.bool(id, .repositoryShowsDetails, default: true) == true)
    }

    @Test("persists a toggle and reads it back")
    func persistsAndReadsBack() {
        let id = freshWorkspaceID()
        defer { RailDisclosureStore.clear(id) }
        RailDisclosureStore.setBool(true, id, .readyCapabilitiesExpanded)
        #expect(RailDisclosureStore.bool(id, .readyCapabilitiesExpanded, default: false) == true)

        RailDisclosureStore.setBool(false, id, .readyCapabilitiesExpanded)
        // An explicit false must win over a true default — proving presence is
        // distinguished from absence.
        #expect(RailDisclosureStore.bool(id, .readyCapabilitiesExpanded, default: true) == false)
    }

    @Test("one workspace's layout does not leak into another")
    func isolatesPerWorkspace() {
        let a = freshWorkspaceID()
        let b = freshWorkspaceID()
        defer { RailDisclosureStore.clear(a); RailDisclosureStore.clear(b) }
        RailDisclosureStore.setBool(true, a, .draftCapabilitiesExpanded)
        #expect(RailDisclosureStore.bool(a, .draftCapabilitiesExpanded, default: false) == true)
        #expect(RailDisclosureStore.bool(b, .draftCapabilitiesExpanded, default: false) == false)
    }
}
