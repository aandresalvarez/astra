import SwiftUI

extension View {
    /// Explains why a folder chosen for the workspace wasn't added.
    func workspaceFolderRefusalAlert(_ message: Binding<String?>) -> some View {
        alert("Folder not added", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
