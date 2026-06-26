import SwiftUI

struct WorkspaceEmptyStateView: View {
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(Stanford.ui(48))
                .foregroundStyle(Stanford.cardinalRed)

            VStack(spacing: 8) {
                Text("Pick a Workspace")
                    .font(Stanford.heading(24))
                    .foregroundStyle(Stanford.black)

                Text("Tasks always belong to a workspace. Create a new one or import an existing folder — ASTRA will reopen it automatically next time.")
                    .font(Stanford.body(15))
                    .foregroundStyle(Stanford.coolGrey)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button {
                    onCreateWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(StanfordButtonStyle())
                .accessibilityIdentifier("OnboardingNewWorkspaceButton")

                Button {
                    onImportWorkspace()
                } label: {
                    Label("Import Workspace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))

                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Stanford.panelBackground)
    }
}
