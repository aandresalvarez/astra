import SwiftUI

extension TaskDecisionDockTone {
    /// The tone palette every composer dock strip shares.
    var dockColor: Color {
        switch self {
        case .neutral:
            Stanford.coolGrey
        case .running:
            Stanford.lagunita
        case .attention:
            Stanford.poppy
        case .failed:
            Stanford.failed
        case .success, .verified, .closed:
            Stanford.statusHealthy
        }
    }

    /// A status glyph is not tappable, so it never wears the interactive
    /// accent: the running tone drops to the info tint instead of lagunita.
    var dockStatusIconColor: Color {
        self == .running ? Stanford.statusInfo : dockColor
    }
}

extension View {
    /// One composer dock row: compact padding and a leading tone bar, with no
    /// nested card. The decision dock and the new-task strip both use it.
    func composerDockRowChrome(tone: TaskDecisionDockTone) -> some View {
        padding(.horizontal, TaskComposerPresentation.decisionRowHorizontalPadding)
            .padding(.vertical, TaskComposerPresentation.decisionRowVerticalPadding)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tone.dockColor.opacity(0.76))
                    .frame(width: TaskComposerPresentation.decisionAccentWidth)
                    .padding(.vertical, TaskComposerPresentation.decisionAccentVerticalInset)
                    .padding(.leading, 1)
            }
    }
}
