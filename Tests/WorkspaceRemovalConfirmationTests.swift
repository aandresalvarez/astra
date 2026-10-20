import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace removal confirmation")
@MainActor
struct WorkspaceRemovalConfirmationTests {
    @Test("Cancel and presentation dismissal clear the pending workspace without deleting it")
    func cancellation() {
        let box = PendingWorkspace()
        var removed: [UUID] = []
        let confirmation = WorkspaceRemovalConfirmation(pendingWorkspace: box.binding) { removed.append($0.id) }
        box.value = Workspace(name: "Project", primaryPath: "/tmp/project")
        #expect(confirmation.isPresented.wrappedValue)
        confirmation.cancel()
        #expect(box.value == nil)
        #expect(removed.isEmpty)
        box.value = Workspace(name: "Other", primaryPath: "/tmp/other")
        confirmation.isPresented.wrappedValue = false
        #expect(box.value == nil)
        #expect(removed.isEmpty)
    }

    @Test("Only explicit confirmation removes the pending workspace, once")
    func confirmation() {
        let box = PendingWorkspace()
        let workspace = Workspace(name: "Project", primaryPath: "/tmp/project")
        box.value = workspace
        var removed: [UUID] = []
        let confirmation = WorkspaceRemovalConfirmation(pendingWorkspace: box.binding) { removed.append($0.id) }
        #expect(removed.isEmpty)
        confirmation.confirm()
        #expect(removed == [workspace.id])
        #expect(box.value == nil)
        #expect(!confirmation.isPresented.wrappedValue)
        confirmation.confirm()
        #expect(removed == [workspace.id])
    }

    @Test("The warning retains the workspace name, task count, and irreversible-action notice")
    func warning() {
        #expect(WorkspaceRemovalConfirmation.message(name: "Project", taskCount: 1)
            == "This removes Project and its 1 task from ASTRA. This cannot be undone.")
        #expect(WorkspaceRemovalConfirmation.message(name: "Other", taskCount: 2)
            == "This removes Other and its 2 tasks from ASTRA. This cannot be undone.")
    }
}

@MainActor
private final class PendingWorkspace {
    var value: Workspace?
    var binding: Binding<Workspace?> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}
