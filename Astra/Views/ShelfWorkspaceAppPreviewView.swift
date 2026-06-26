import SwiftUI

/// The live app preview docked in the right shelf while you build an app by chatting
/// (the Lovable/Replit "right pane"). It reuses the existing full interactive preview —
/// `WorkspaceAppPreviewView` — so what you test here is the exact `WorkspaceAppSurfaceView`
/// a published app renders, with storage CRUD running against an in-memory sandbox. The
/// preview is keyed on `session.draftRevision`, so each generation/refinement turn rebuilds
/// it from the new manifest (a fresh, disposable test sandbox — by design).
struct ShelfWorkspaceAppPreviewView: View {
    @ObservedObject var session: WorkspaceAppStudioSession
    /// The workspace the draft belongs to — threaded into the preview so a connector-read app can
    /// resolve LIVE, read-only `astra.read` data (real `gh` PRs etc.) before publishing. nil ⇒ reads
    /// stay simulated.
    var workspace: Workspace?
    /// Collapses the preview shelf (the preview's own "Done" button).
    var onClose: () -> Void

    var body: some View {
        Group {
            if session.isBuildingFirstDraft {
                // A first build is still generating: show a clear "building" status instead of the
                // generic deterministic provisional, which otherwise reads as a finished (or different)
                // app. Once the result lands, the real app replaces this.
                buildingState
            } else if let draft = session.draft {
                WorkspaceAppPreviewView(manifest: draft.manifest, workspace: workspace, onClose: onClose, minWidth: 400)
                    // A new draft => a new sandbox: discard the prior preview's in-memory edits.
                    .id(session.draftRevision)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("ShelfWorkspaceAppPreviewView")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live preview")
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Sandbox · nothing is written or saved")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Stanford.cardBackground)
    }

    private var buildingState: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                Spacer()
                ProgressView().controlSize(.large)
                Text("Building your app…")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(buildingDetail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .accessibilityIdentifier("ShelfWorkspaceAppPreviewBuilding")
        }
    }

    private var buildingDetail: String {
        if let name = session.appName, !name.isEmpty, name != "Workspace App" {
            return "Generating “\(name)” from your description. This can take a moment — it appears here when it's ready, and you can try it before publishing."
        }
        return "Generating your app from your description. This can take a moment — it appears here when it's ready, and you can try it before publishing."
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wand.and.sparkles")
                    .font(Stanford.ui(30, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text("Your app will appear here")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Describe what you want to track, review, or report on in the chat. The app builds here as you go, and you can try it before publishing.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }
}
