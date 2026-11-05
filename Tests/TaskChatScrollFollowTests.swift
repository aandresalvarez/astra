import AppKit
import Testing
@testable import ASTRA

@MainActor
@Suite("Task chat follow layout")
struct TaskChatScrollFollowTests {
    private func snapshot(_ revision: Int) -> TaskThreadSnapshotReadiness {
        TaskThreadSnapshotReadiness(taskID: nil, revision: revision)
    }

    @Test("Layout growth before and after the deferred follow handler cannot pause live history")
    func layoutDoesNotImpersonateUserScroll() throws {
        let state = TaskChatFollowLayoutState()
        let source = snapshot(2)
        #expect(state.shouldDeferBottomChange(isFollowing: true, snapshot: source))
        state.noteSnapshotHandled(source)
        let pending = state.beginFollow(snapshot: source)
        let follow = try #require(pending)
        #expect(state.shouldDeferBottomChange(isFollowing: true, snapshot: source))
        #expect(state.isCurrent(follow, snapshot: source))
        state.finish(follow)
        #expect(!state.shouldDeferBottomChange(isFollowing: true, snapshot: source))
        #expect(!state.shouldDeferBottomChange(isFollowing: false, snapshot: snapshot(3)))
    }

    @Test("User input cancels an outstanding follow before geometry arrives")
    func userScrollWins() throws {
        let state = TaskChatFollowLayoutState()
        let source = snapshot(2)
        let pending = state.beginFollow(snapshot: source)
        let follow = try #require(pending)
        let measuredInput = state.inputRevision
        state.noteUserScroll(snapshot: source)
        #expect(state.inputRevision != measuredInput, "Queued pre-input geometry must be rejected")
        #expect(!state.isCurrent(follow, snapshot: source))
        #expect(!state.shouldDeferBottomChange(isFollowing: true, snapshot: source))
        let suppressed = state.beginFollow(snapshot: source)
        #expect(suppressed == nil)
        state.resumeFollowing()
        let resumed = state.beginFollow(snapshot: source)
        #expect(resumed != nil)
    }

    @Test("An older follow completion cannot clear a newer snapshot's pending layout")
    func supersededFollowCannotFinishNewLayout() throws {
        let state = TaskChatFollowLayoutState()
        let first = state.beginFollow(snapshot: snapshot(1))
        let older = try #require(first)
        let second = state.beginFollow(snapshot: snapshot(2))
        let newer = try #require(second)
        state.finish(older)
        #expect(!state.isCurrent(older, snapshot: snapshot(2)))
        #expect(state.isCurrent(newer, snapshot: snapshot(2)))
        #expect(state.shouldDeferBottomChange(isFollowing: true, snapshot: snapshot(2)))
        state.reset()
        #expect(!state.isCurrent(newer, snapshot: snapshot(2)))
    }

    @Test("Native scroll observation is scoped and excludes programmatic clip movement")
    func nativeInteractionScope() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let reader = TaskChatScrollInteractionReader.InteractionView(frame: NSRect(x: 0, y: 16, width: 400, height: 1))
        document.addSubview(reader)
        scroll.documentView = document
        var inputs: [Bool] = []
        reader.onScroll = { inputs.append($0) }
        reader.observeEnclosingScrollView()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(inputs.isEmpty)
        let foreign = NSScrollView()
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: foreign)
        #expect(inputs.isEmpty)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(inputs == [false])
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(inputs == [false, true])
        reader.stop()
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(inputs == [false, true])
    }
}
