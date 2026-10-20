import SwiftUI
import ASTRAModels

/// Keeps alert type inference separate from the sidebar's large view tree.
/// The sidebar still owns the pending workspace through this binding.
struct WorkspaceRemovalConfirmation: ViewModifier {
    @Binding var pendingWorkspace: Workspace?
    let onRemove: ((Workspace) -> Void)?

    var isPresented: Binding<Bool> {
        Binding<Bool>(
            get: { pendingWorkspace != nil },
            set: { if !$0 { cancel() } }
        )
    }

    func body(content: Content) -> some View {
        content.alert("Remove Workspace from ASTRA?", isPresented: isPresented) {
            Button("Cancel", role: .cancel, action: cancel)
            Button("Remove", role: .destructive, action: confirm)
        } message: {
            if let workspace = pendingWorkspace {
                Text(Self.message(name: workspace.name, taskCount: workspace.tasks.count))
            }
        }
    }

    func cancel() {
        pendingWorkspace = nil
    }

    func confirm() {
        if let workspace = pendingWorkspace { onRemove?(workspace) }
        pendingWorkspace = nil
    }

    static func message(name: String, taskCount: Int) -> String {
        let noun = taskCount == 1 ? "task" : "tasks"
        return "This removes \(name) and its \(taskCount) \(noun) from ASTRA. This cannot be undone."
    }
}
