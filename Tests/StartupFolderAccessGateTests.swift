import Testing
import Foundation
import os
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
            return false
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
            return false
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

    @Test("A folder macOS refuses stops the gate at the refusal, with every refused folder named")
    func refusedFoldersAreNamedAndNothingOpens() async {
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            return folder.hasPrefix("/refused")
        }
        await gate.open(folders: { ["/allowed", "/refused-one", "/refused-two"] })

        // Every folder is asked, so the person hears about all of them at once.
        #expect(probe.folders == ["/allowed", "/refused-one", "/refused-two"])
        #expect(gate.state == .refused(["/refused-one", "/refused-two"]))
        #expect(!gate.isOpen)
        #expect(gate.waitingOn == nil)

        // A second window finds the refusal already known and asks nothing.
        await gate.open(folders: { probe.noteAsked(); return ["/allowed"] })
        #expect(probe.timesAsked == 0)
        #expect(gate.state == .refused(["/refused-one", "/refused-two"]))
    }

    @Test("Trying again asks only the refused folders, and opens the gate once macOS allows them")
    func tryingAgainAfterAllowingOpensTheGate() async {
        let probe = FolderTouchProbe()
        let allowed = OSAllocatedUnfairLock(initialState: false)
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            return folder == "/documents" && !allowed.withLock { $0 }
        }
        await gate.open(folders: { ["/elsewhere", "/documents"] })
        #expect(gate.state == .refused(["/documents"]))

        // Still refused: the same screen comes back.
        await gate.tryAgain()
        #expect(gate.state == .refused(["/documents"]))

        allowed.withLock { $0 = true }
        await gate.tryAgain()
        #expect(gate.isOpen)
        #expect(probe.folders == ["/elsewhere", "/documents", "/documents", "/documents"])
        #expect(probe.ranOnMain.allSatisfy { !$0 })

        // Nothing is left to try once the gate is open.
        await gate.tryAgain()
        #expect(probe.folders.count == 4)
    }

    @Test("Continuing anyway opens the gate over a refusal, and is not a way past a wait")
    func continuingAnywayIsOnlyForARefusal() async {
        let release = DispatchSemaphore(value: 0)
        let probe = FolderTouchProbe()
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            _ = release.wait(timeout: .now() + 30)
            return true
        }
        let opening = Task { await gate.open(folders: { ["/blocked"] }) }
        await waitUntil(gate, isOpening: "/blocked", probe)

        // While a folder has not answered, nothing opens the gate early:
        // that would put the wait back on the main actor.
        gate.continueAnyway()
        await gate.tryAgain()
        #expect(gate.state == .waiting)
        #expect(probe.folders == ["/blocked"])

        release.signal()
        await opening.value
        #expect(gate.state == .refused(["/blocked"]))

        gate.continueAnyway()
        #expect(gate.isOpen)
    }

    @Test("No folders opens the gate without touching anything; repeats and empty paths are dropped")
    func emptyAndRepeatedFolders() async {
        let probe = FolderTouchProbe()
        let empty = StartupFolderAccessGate(startsOpen: false) { probe.note($0); return false }
        await empty.open(folders: { [] })
        #expect(empty.isOpen)
        #expect(probe.folders.isEmpty)

        let repeated = StartupFolderAccessGate(startsOpen: false) { probe.note($0); return false }
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
        let gate = StartupFolderAccessGate(startsOpen: true) { probe.note($0); return false }
        await gate.open(folders: { probe.noteAsked(); return ["/a"] })
        #expect(gate.isOpen)
        #expect(probe.timesAsked == 0)
        #expect(probe.folders.isEmpty)
    }

    @Test("The real check answers for a folder, a missing path, a file and a folder closed by file permissions, and none is a privacy refusal")
    func realCheckAnswersWhateverIsThere() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-folder-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("closed").path)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let closed = root.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)

        #expect(!StartupFolderAccessGate.isRefused(root.path))
        #expect(!StartupFolderAccessGate.isRefused(root.appendingPathComponent("missing").path))
        #expect(!StartupFolderAccessGate.isRefused(file.path))
        // File permissions are not the privacy setting: sending the person to
        // System Settings would not help, so this is not reported as refused.
        #expect(!StartupFolderAccessGate.isRefused(closed.path))
        // Nothing is created, changed or left open by asking.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["closed", "file.txt"])
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
        let gate = StartupFolderAccessGate(startsOpen: false) { _ in false }
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
        let gate = StartupFolderAccessGate(startsOpen: false) { probe.note($0); return false }
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

    @Test("On screen, a refusal keeps the content unbuilt until trying again finds the folder allowed")
    func hostedRootHoldsARefusalUntilItIsAllowed() async {
        let probe = FolderTouchProbe()
        let allowed = OSAllocatedUnfairLock(initialState: false)
        let gate = StartupFolderAccessGate(startsOpen: false) { folder in
            probe.note(folder)
            return !allowed.withLock { $0 }
        }
        let root = StartupFolderAccessRoot(gate: gate, folders: { ["/hosted-refused"] }) {
            Color.clear.onAppear { probe.noteAsked() }
        }
        let host = NSHostingView(rootView: root.frame(width: 640, height: 420))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        HostLifetime.retained.append(contentsOf: [host, window])
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        await settle(until: { gate.state == .refused(["/hosted-refused"]) })
        #expect(gate.state == .refused(["/hosted-refused"]))
        await settle(until: { false }, turns: 5)
        #expect(probe.timesAsked == 0)

        allowed.withLock { $0 = true }
        await gate.tryAgain()
        await settle(until: { probe.timesAsked == 1 })
        #expect(gate.isOpen)
        #expect(probe.timesAsked == 1)
    }

    @Test("Every refused folder can be read off the refusal screen: few are listed outright, many on request")
    func everyRefusedFolderCanBeListed() {
        let few = ["/a", "/b", "/c"]
        #expect(StartupFolderAccessRefusedNotice.listed(few, showingAll: false) == few)

        let many = (1...7).map { "/workspace-\($0)" }
        #expect(StartupFolderAccessRefusedNotice.listed(many, showingAll: false) == Array(many.prefix(3)))
        #expect(StartupFolderAccessRefusedNotice.listed(many, showingAll: true) == many)
        #expect(StartupFolderAccessRefusedNotice.subject(1) == "this workspace folder")
        #expect(StartupFolderAccessRefusedNotice.subject(7) == "7 workspace folders")
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
