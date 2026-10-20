import AppKit
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace folder row hit targets", .serialized)
@MainActor
struct WorkspaceFolderRowHitTargetTests {
    @Test("Every edge of the shaded row toggles the folder exactly once")
    func entireSurfaceToggles() throws {
        let fixture = RowFixture()
        defer { fixture.tearDown() }
        // First prove the harness reaches the actual SwiftUI button.
        try fixture.click(x: 100, y: fixture.height / 2)
        #expect(fixture.toggles == 1)
        for point in [CGPoint(x: 100, y: 1), CGPoint(x: 100, y: fixture.height - 1),
                      CGPoint(x: 1, y: fixture.height / 2), CGPoint(x: 319, y: fixture.height / 2),
                      CGPoint(x: 275, y: fixture.height / 2), CGPoint(x: 304, y: 1), CGPoint(x: 304, y: fixture.height - 1)] {
            let previous = fixture.toggles
            try fixture.click(x: point.x, y: point.y)
            #expect(fixture.toggles == previous + 1, "Missed or doubled disclosure at \(point)")
            #expect(fixture.newTasks == 0)
        }
    }

    @Test("Resting status, star, and composer markers do not block disclosure")
    func restingMetadataPassesClicksThrough() throws {
        let fixture = RowFixture(hovered: false, newTaskTarget: true)
        defer { fixture.tearDown() }
        for x: CGFloat in [240, 275, 304, 319] {
            let previous = fixture.toggles
            try fixture.click(x: x, y: fixture.height / 2)
            #expect(fixture.toggles == previous + 1)
            #expect(fixture.newTasks == 0)
        }
    }

    @Test("Manual reorder mode preserves the lower edge and independent new-task action")
    func manualModeEdges() throws {
        let fixture = RowFixture(manual: true)
        defer { fixture.tearDown() }
        for x: CGFloat in [10, 100, 304, 319] {
            let previous = fixture.toggles
            try fixture.click(x: x, y: fixture.height - 1)
            #expect(fixture.toggles == previous + 1)
        }
        try fixture.click(x: 304, y: fixture.height / 2)
        #expect(fixture.toggles == 4)
        #expect(fixture.newTasks == 1)
    }

    @Test("The new-task button stays independent from folder disclosure")
    func newTaskDoesNotToggle() throws {
        let fixture = RowFixture()
        defer { fixture.tearDown() }
        try fixture.click(x: 304, y: fixture.height / 2)
        #expect(fixture.newTasks == 1)
        #expect(fixture.toggles == 0)
    }
}

@MainActor
private final class RowFixture {
    var toggles = 0
    var newTasks = 0
    let height = Stanford.sidebarWorkspaceRowHeight
    let window: NSWindow
    private var host: NSHostingView<AnyView>!

    init(hovered: Bool = true, newTaskTarget: Bool = false, manual: Bool = false) {
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: height + 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = Workspace(name: "Project", primaryPath: "/tmp/project")
        workspace.isStarred = true
        let row = WorkspaceFolderRow(
            workspace: workspace,
            isExpanded: false, isSelected: false, isHovered: hovered, isNewTaskTarget: newTaskTarget,
            activityCounts: .init(running: 2, waiting: 1), allowsReordering: manual,
            onToggle: { [weak self] in self?.toggles += 1 },
            onNewTask: { [weak self] in self?.newTasks += 1 },
            onBeginDrag: { NSItemProvider() }
        )
        host = ClickHostingView(rootView: AnyView(row.frame(width: 320, height: height).padding(20)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    func click(x: CGFloat, y: CGFloat) throws {
        // Events are delivered only to this offscreen test window. They never
        // enter the system event queue or interact with the user's ASTRA app.
        let location = host.convert(NSPoint(x: x + 20, y: y + 20), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func tearDown() {
        window.contentView = nil
        host.removeFromSuperview()
        window.close()
    }
}

@MainActor
private final class ClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
