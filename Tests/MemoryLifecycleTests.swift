import Foundation
import Testing
@testable import ASTRA

@MainActor
@Suite("Memory lifecycle")
struct MemoryLifecycleTests {
    @Test("right-panel presentation model releases with its owner")
    func rightPanelPresentationModelReleases() throws {
        let suiteName = "memory-lifecycle.right-panel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        weak var releasedModel: RightPanelPresentationModel?

        do {
            let model = RightPanelPresentationModel(defaults: defaults)
            model.presentCanvas(.markdown)
            releasedModel = model
        }

        #expect(releasedModel == nil)
    }

    @Test("releasing a browser task session drops the store's strong ownership")
    func browserTaskSessionReleases() {
        ShelfBrowserBridgeRegistry.shared.reset()
        let store = ShelfBrowserSessionStore(evictionEligibility: { _ in true })
        let taskID = UUID()
        weak var releasedSession: ShelfBrowserSession?

        do {
            let session = store.session(for: taskID, pinnedToTask: true, enabledBrowserAdapters: [])
            releasedSession = session
        }
        store.releaseSession(for: taskID)

        #expect(!store.hasTaskSessionForTesting(taskID))
        #expect(releasedSession == nil)
    }

    @Test("releasing markdown task and workspace sessions drops store ownership")
    func markdownSessionsRelease() {
        let store = ShelfMarkdownSessionStore()
        let taskID = UUID()
        let workspaceID = UUID()
        weak var releasedTaskSession: ShelfMarkdownSession?
        weak var releasedWorkspaceSession: ShelfMarkdownSession?

        do {
            let taskSession = store.session(for: taskID, workspaceID: workspaceID, pinnedToTask: true)
            let workspaceSession = store.session(for: nil, workspaceID: workspaceID, pinnedToTask: false)
            releasedTaskSession = taskSession
            releasedWorkspaceSession = workspaceSession
        }
        store.releaseSession(for: taskID)
        store.releaseSession(forWorkspaceID: workspaceID)

        #expect(store.taskSessionCountForTesting == 0)
        #expect(store.workspaceSessionCountForTesting == 0)
        #expect(releasedTaskSession == nil)
        #expect(releasedWorkspaceSession == nil)
    }
}
