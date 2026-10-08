import SwiftUI

extension View {
    /// Explains why a folder chosen for the workspace wasn't added.
    func workspaceFolderRefusalAlert(_ message: Binding<String?>) -> some View {
        dismissibleMessageAlert("Folder not added", message: message)
    }

    /// Explains why a task the user deleted is still there.
    func taskDeletionFailureAlert(_ message: Binding<String?>) -> some View {
        dismissibleMessageAlert("Task not deleted", message: message)
    }

    private func dismissibleMessageAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
