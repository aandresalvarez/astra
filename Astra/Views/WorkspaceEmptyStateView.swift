import SwiftUI

struct WorkspaceEmptyStateView: View {
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(Stanford.ui(48))
                .foregroundStyle(Stanford.interactive)

            VStack(spacing: 8) {
                Text(WorkspaceAvailabilityPresentation.onboardingTitle)
                    .font(Stanford.heading(24))
                    .foregroundStyle(Stanford.black)

                Text(WorkspaceAvailabilityPresentation.onboardingBody)
                    .font(Stanford.body(15))
                    .foregroundStyle(Stanford.coolGrey)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                Text(WorkspaceAvailabilityPresentation.onboardingFootnote)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.textTertiary)
            }

            HStack(spacing: 12) {
                Button {
                    onCreateWorkspace()
                } label: {
                    Label("Create Workspace", systemImage: "plus")
                }
                .buttonStyle(StanfordButtonStyle())
                .accessibilityIdentifier("OnboardingNewWorkspaceButton")
                .accessibilityLabel("Create Workspace")

                Button {
                    onImportWorkspace()
                } label: {
                    Label("Import Folder", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .accessibilityIdentifier("OnboardingImportWorkspaceButton")
                .accessibilityLabel("Import Folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Stanford.panelBackground)
    }
}
