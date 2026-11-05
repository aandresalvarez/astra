import AppKit
import SwiftUI

/// Presentation bookkeeping for the layout beats between applying a bounded
/// transcript and following its bottom. Real scroll input cancels pending work.
/// Deliberately not observable: per-frame native input must not rebuild the
/// eager transcript. TaskMainView's at-bottom state owns visible changes.
@MainActor
final class TaskChatFollowLayoutState {
    struct Token: Equatable {
        let generation: Int
        let snapshot: TaskThreadSnapshotReadiness
    }

    private var generation = 0
    private(set) var inputRevision = 0
    private var handledSnapshot: TaskThreadSnapshotReadiness?
    private var userScrollSnapshot: TaskThreadSnapshotReadiness?
    private var pendingFollow: Token?

    func reset() {
        resumeFollowing()
        handledSnapshot = nil
    }

    func resumeFollowing() {
        generation &+= 1
        inputRevision &+= 1
        userScrollSnapshot = nil
        pendingFollow = nil
    }

    func noteUserScroll(snapshot: TaskThreadSnapshotReadiness) {
        generation &+= 1
        inputRevision &+= 1
        userScrollSnapshot = snapshot
        pendingFollow = nil
    }

    func noteSnapshotHandled(_ snapshot: TaskThreadSnapshotReadiness) {
        handledSnapshot = snapshot
    }

    func shouldDeferBottomChange(isFollowing: Bool, snapshot: TaskThreadSnapshotReadiness) -> Bool {
        isFollowing && userScrollSnapshot != snapshot
            && (handledSnapshot != snapshot || pendingFollow != nil)
    }

    func beginFollow(snapshot: TaskThreadSnapshotReadiness) -> Token? {
        guard userScrollSnapshot != snapshot else { return nil }
        generation &+= 1
        let token = Token(generation: generation, snapshot: snapshot)
        handledSnapshot = snapshot
        pendingFollow = token
        return token
    }

    func isCurrent(_ token: Token, snapshot: TaskThreadSnapshotReadiness) -> Bool {
        pendingFollow == token && token.snapshot == snapshot && userScrollSnapshot != snapshot
    }

    func finish(_ token: Token) {
        if pendingFollow == token { pendingFollow = nil }
    }
}

/// Observe input only over this transcript. Geometry alone cannot distinguish
/// a taller replacement row from a reader moving away from the bottom.
struct TaskChatScrollInteractionReader: NSViewRepresentable {
    var onScroll: (Bool) -> Void

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onScroll = onScroll
        view.observeEnclosingScrollView()
    }

    static func dismantleNSView(_ view: InteractionView, coordinator: ()) { view.stop() }

    @MainActor
    final class InteractionView: NSView {
        var onScroll: ((Bool) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
            else { observeEnclosingScrollView() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeEnclosingScrollView()
        }

        func observeEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else { stop(); return }
            guard observedScrollView !== scrollView else { return }
            stop()
            observedScrollView = scrollView
            let sourceID = ObjectIdentifier(scrollView)
            // AppKit sends this on the main thread after user-initiated clip
            // movement, including legacy wheels. Programmatic follows do not.
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                object: scrollView, queue: nil) { [weak self] note in
                guard let source = note.object as? NSScrollView, ObjectIdentifier(source) == sourceID else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let clip = source.contentView
                    let sentinel = self.convert(self.bounds, to: clip)
                    let bottomMinY = clip.isFlipped
                        ? sentinel.minY - clip.bounds.minY : clip.bounds.maxY - sentinel.maxY
                    self.onScroll?(ChatScrollMetrics.isAtBottom(bottomMinY: bottomMinY, viewportHeight: clip.bounds.height))
                }
            })
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            observedScrollView = nil
        }
    }
}
