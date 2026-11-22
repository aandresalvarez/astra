import Testing
import Foundation
import SwiftData
import SwiftUI
import ASTRAModels
@testable import ASTRA

// A new build's first read inside Documents raises a macOS privacy prompt that
// blocks the read until it is answered. The main window's startup work reads
// workspace folders on the main actor, so that wait used to be an app with no
// window that did not respond. The gate takes the wait first, off the main
// actor, and the main window is built only after it.

private final class FolderTouchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var touched: [String] = []
    private var onMain: [Bool] = []
    private var asked = 0

    func note(_ folder: String) {
        lock.withLock {
            touched.append(folder)
            onMain.append(Thread.isMainThread)
        }
    }
    func noteAsked() { lock.withLock { asked += 1 } }
    var folders: [String] { lock.withLock { touched } }
    var ranOnMain: [Bool] { lock.withLock { onMain } }
    var timesAsked: Int { lock.withLock { asked } }
}

@Suite("Startup folder access gate")
@MainActor
struct StartupFolderAccessGateTests {
    /// Waits, a bounded number of turns, until `folder` is being opened: the
    /// gate names it a moment before its queue reaches the open.
    private func waitUntil(_ gate: StartupFolderAccessGate, isOpening folder: String, _ probe: FolderTouchProbe) async {
        for _ in 0..<2_000 where gate.waitingOn != folder || probe.folders.last != folder {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("A folder that does not answer holds the gate's queue, never the main actor")
    func blockedFolderLeavesTheMainActorFree() async {
        let release = DispatchSemaphore(value: 0)
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            if folder == "/blocked" { _ = release.wait(timeout: .now() + 30) }
        }
        let opening = Task { await gate.open(folders: { ["/blocked", "/next"] }) }
        await waitUntil(gate, isOpening: "/blocked", probe)

        // The main actor is running this test while the open is still blocked.
        #expect(gate.waitingOn == "/blocked")
        #expect(!gate.isOpen)
        #expect(probe.folders == ["/blocked"])

        release.signal()
        await opening.value
        #expect(gate.isOpen)
        #expect(gate.waitingOn == nil)
        #expect(probe.folders == ["/blocked", "/next"])
        #expect(probe.ranOnMain == [false, false])
    }

    @Test("Every window awaits one wait, and the folders are asked for once")
    func concurrentOpensShareOneWait() async {
        let release = DispatchSemaphore(value: 0)
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            _ = release.wait(timeout: .now() + 30)
        }
        let folders: () -> [String] = {
            probe.noteAsked()
            return ["/only"]
        }
        let first = Task { await gate.open(folders: folders) }
        await waitUntil(gate, isOpening: "/only", probe)
        let second = Task { await gate.open(folders: folders) }
        await Task.yield()
        #expect(!gate.isOpen)

        release.signal()
        await first.value
        await second.value
        #expect(gate.isOpen)
        #expect(probe.folders == ["/only"])
        #expect(probe.timesAsked == 1)

        // An open gate asks nothing more.
        await gate.open(folders: folders)
        #expect(probe.timesAsked == 1)
    }

    @Test("Choosing not to wait opens the gate at once and asks no further folder")
    func skippingOpensWithoutTheAnswer() async {
        let release = DispatchSemaphore(value: 0)
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            _ = release.wait(timeout: .now() + 30)
        }
        let opening = Task { await gate.open(folders: { ["/blocked", "/never-asked"] }) }
        await waitUntil(gate, isOpening: "/blocked", probe)

        gate.skip()
        #expect(gate.isOpen)

        release.signal()
        await opening.value
        #expect(gate.isOpen)
        #expect(gate.waitingOn == nil)
        #expect(probe.folders == ["/blocked"])
    }

    @Test("No folders opens the gate without touching anything; repeats and empty paths are dropped")
    func emptyAndRepeatedFolders() async {
        let probe = FolderTouchProbe()
        let empty = StartupFolderAccessGate(startsOpen: false) { probe.note($0) }
        await empty.open(folders: { [] })
        #expect(empty.isOpen)
        #expect(probe.folders.isEmpty)

        let repeated = StartupFolderAccessGate(startsOpen: false) { probe.note($0) }
        await repeated.open(folders: { ["/a", "", "/b", "/a"] })
        #expect(repeated.isOpen)
        #expect(probe.folders == ["/a", "/b"])
    }

    @Test("A UI test launch waits on nothing")
    func uiTestLaunchesStartOpen() async {
        #expect(StartupFolderAccessGate.isSkipped(arguments: ["ASTRA", "--uitesting-seed"]))
        #expect(StartupFolderAccessGate.isSkipped(arguments: ["ASTRA", "--uitesting"]))
        #expect(!StartupFolderAccessGate.isSkipped(arguments: ["ASTRA", "--skip-workspace-recovery"]))

        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: true) { probe.note($0) }
        await gate.open(folders: { probe.noteAsked(); return ["/a"] })
        #expect(gate.isOpen)
        #expect(probe.timesAsked == 0)
        #expect(probe.folders.isEmpty)
    }

    @Test("The real touch returns for a folder, a missing path and a file")
    func realTouchAnswersWhateverIsThere() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-folder-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        StartupFolderAccessGate.touch(root.path)
        StartupFolderAccessGate.touch(root.appendingPathComponent("missing").path)
        StartupFolderAccessGate.touch(file.path)
        // Nothing is created, changed or left open by asking.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])
    }

    @Test("The folders waited on are every stored workspace's")
    func storedWorkspaceFolders() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        #expect(StartupFolderAccessGate.workspaceFolders(in: context).isEmpty)

        context.insert(Workspace(name: "One", primaryPath: "/workspaces/one"))
        context.insert(Workspace(name: "Two", primaryPath: "/workspaces/two"))
        try context.save()
        #expect(Set(StartupFolderAccessGate.workspaceFolders(in: context)) == ["/workspaces/one", "/workspaces/two"])
    }

    @Test("The main window's content is not built while the gate is closed")
    func contentIsBuiltOnlyBehindAnOpenGate() async {
        var built = 0
        let gate = StartupFolderAccessGate(startsOpen: false) { _ in }
        let root = StartupFolderAccessRoot(gate: gate, folders: { [] }) { () -> Text in
            built += 1
            return Text("main")
        }
        _ = root.body
        #expect(built == 0)

        await gate.open(folders: { [] })
        _ = root.body
        #expect(built == 1)
    }

    /// Kept for the life of the test process: tearing a hosted SwiftUI window
    /// down mid-suite has crashed later suites here.
    private enum HostLifetime {
        @MainActor static var retained: [Any] = []
    }

    /// Run-loop turns drive the hosted view; main-actor turns run what it
    /// schedules. Bounded by turns, not wall clock.
    private func settle(until predicate: () -> Bool, turns: Int = 600) async {
        for _ in 0..<turns {
            if predicate() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // The waiting view shows nothing at first. It still has to be a view, or
    // the task that opens the gate never starts and the window stays empty.
    @Test("On screen, the root opens the gate by itself and then builds the content")
    func hostedRootOpensTheGate() async {
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { probe.note($0) }
        let root = StartupFolderAccessRoot(gate: gate, folders: { ["/hosted"] }) {
            Color.clear.onAppear { probe.noteAsked() }
        }
        let host = NSHostingView(rootView: root.frame(width: 200, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        HostLifetime.retained.append(contentsOf: [host, window])
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        await settle(until: { gate.isOpen && probe.timesAsked == 1 })
        #expect(gate.isOpen)
        #expect(probe.folders == ["/hosted"])
        // The content appeared, once, after the gate opened.
        #expect(probe.timesAsked == 1)
    }

    @Test("The app builds its main view behind the gate and keeps links that arrive before it")
    func appRootIsGated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8)
        let main = try #require(app.range(of: "case .main:"))
        let gated = try #require(app.range(of: "StartupFolderAccessRoot(gate: folderAccess", range: main.upperBound..<app.endIndex))
        let content = try #require(app.range(of: "ContentView(", range: main.upperBound..<app.endIndex))
        #expect(gated.lowerBound < content.lowerBound)
        // One main view, and it is the gated one.
        #expect(app.components(separatedBy: "ContentView(").count == 2)
        // The link handler sits on the gate's root, after the content closure,
        // so it is there while the gate is still closed.
        let onAppear = try #require(app.range(of: ".onAppear {", range: content.upperBound..<app.endIndex))
        let openURL = try #require(app.range(of: ".onOpenURL {", range: content.upperBound..<app.endIndex))
        let indentation = { (range: Range<String.Index>) -> Int in
            app[..<range.lowerBound].reversed().prefix { $0 == " " }.count
        }
        #expect(onAppear.lowerBound < openURL.lowerBound)
        #expect(indentation(openURL) < indentation(onAppear))
    }
}
