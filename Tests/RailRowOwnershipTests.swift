import AppKit
import SwiftUI
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import SwiftData
@testable import ASTRA

@Suite("Rail row ownership", .serialized)
@MainActor
struct RailRowOwnershipTests {
    private typealias Rail = WorkspaceRailSectionPresentation

    @Test("Collapsed headers expose their summary to assistive technology")
    func collapsedHeaderSummary() {
        #expect(RailBoxHeader.accessibilityValue(isExpanded: false, summary: "3 files") == "Collapsed, 3 files")
        #expect(RailBoxHeader.accessibilityValue(isExpanded: true, summary: "3 files") == "Expanded")
        #expect(RailBoxHeader.accessibilityValue(isExpanded: false, summary: "  ") == "Collapsed")
    }

    @Test("An empty Folder row chooses the primary folder; configured rows expand details")
    func emptyFolderAction() throws {
        var choices = 0, toggles = 0
        let view = RailFolderRows(rows: [], isExpanded: false,
            onToggle: { toggles += 1 }, onChoosePrimary: { choices += 1 }) { EmptyView() }
        let empty = try #require(Rail.environmentBox(.init(primaryPath: "")).rows.first { $0.kind == .folder })
        view.activate(empty)
        #expect(choices == 1 && toggles == 0)
        let configured = try #require(Rail.environmentBox(.init(primaryPath: "/tmp/root")).rows.first { $0.kind == .folder })
        view.activate(configured)
        #expect(choices == 1 && toggles == 1)
    }

    @Test("Primary-folder choice persists, cancellation preserves it and cleanup reservations refuse it")
    func primaryFolderChoice() throws {
        let store = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let workspace = Workspace(name: "Empty", primaryPath: "")
        store.mainContext.insert(workspace)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(WorkspaceRailFolderPicker.choose(.primary, for: workspace) { _ in nil } == .unchanged)
        #expect(workspace.primaryPath.isEmpty)
        let reservation = try #require(TaskWorktreeCheckoutReservation.acquire(path))
        #expect(WorkspaceRailFolderPicker.choose(.primary, for: workspace) { _ in path } == .refused(path: path))
        #expect(workspace.primaryPath.isEmpty)
        TaskWorktreeCheckoutReservation.release(reservation)
        #expect(WorkspaceRailFolderPicker.choose(.primary, for: workspace) { _ in path } == .updated)
        try store.mainContext.save()
        let reloaded = try #require(ModelContext(store).fetch(FetchDescriptor<Workspace>()).first)
        #expect(reloaded.primaryPath == path)
        #expect(reloaded.additionalPaths.isEmpty)
        #expect(WorkspaceRailFolderPicker.choose(.primary, for: workspace) { _ in nil } == .unchanged)
        #expect(workspace.primaryPath == path)
    }

    @Test("Capability identity survives readiness reorder and rename")
    func capabilityIdentity() throws {
        let before = try #require(Rail.capabilitiesBox([
            .init(id: "a", name: "Alpha", isBlocked: true),
            .init(id: "b", name: "Bravo", isBlocked: true)
        ]))
        let after = try #require(Rail.capabilitiesBox([
            .init(id: "a", name: "Renamed", isBlocked: false),
            .init(id: "b", name: "Bravo", isBlocked: true)
        ]))
        #expect(before.rows.map(\.kind) != after.rows.map(\.kind))
        #expect(before.rows[0].id == after.rows[1].id)
        #expect(before.rows[1].id == after.rows[0].id)
    }

    @Test("Folder IDs distinguish full paths with identical abbreviated values")
    func fullPathIdentity() {
        let rows = Rail.environmentBox(.init(primaryPath: "/tmp/one/project/src",
            additionalPaths: ["/tmp/two/project/src", "/tmp/one/project/./src"])).rows.filter { $0.kind == .folder }
        #expect(rows.count == 2)
        #expect(rows[0].value == rows[1].value)
        #expect(rows[0].id != rows[1].id)
    }

    @Test("Repair confirmation changes with owner, command, guidance or removal")
    func confirmationIdentity() {
        let action = CLISessionExpiryClassifier.gitHub.repair
        let original = CapabilityRailRepair.confirmationIdentity(for: action, owner: "a")
        #expect(original != CapabilityRailRepair.confirmationIdentity(for: action, owner: "b"))
        var changed = action
        changed.command = "different repair"
        #expect(original != CapabilityRailRepair.confirmationIdentity(for: changed, owner: "a"))
        changed = action
        changed.detail = "Different manual guidance"
        #expect(original != CapabilityRailRepair.confirmationIdentity(for: changed, owner: "a"))
        #expect(original != CapabilityRailRepair.confirmationIdentity(for: nil, owner: "a"))
    }

    @Test("Three expanded folder rows mount exactly one shared editor")
    func oneFolderEditor() {
        let rows = Rail.environmentBox(.init(primaryPath: "/tmp/root", additionalPaths: ["/tmp/a", "/tmp/b"]))
            .rows.filter { $0.kind == .folder }
        var mounts = 0
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack {
            RailFolderRows(rows: rows, isExpanded: true, onToggle: {}, onChoosePrimary: {}) {
                Text("Shared editor").onAppear { mounts += 1 }
            }
        }.frame(width: 340))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(mounts == 1)
    }
}
