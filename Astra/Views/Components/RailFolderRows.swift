import SwiftUI

/// Every folder has a stable scan row; the shared folder editor mounts once.
struct RailFolderRows<Details: View>: View {
    let rows: [WorkspaceRailSectionPresentation.Row]
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var details: () -> Details

    var body: some View {
        ForEach(rows) { row in
            RailKeyValueRow(row: row, isExpanded: isExpanded, help: row.representedPath,
                            onTap: onToggle, onAction: onToggle)
        }
        if !rows.isEmpty, isExpanded {
            details()
                .padding(.leading, WorkspaceRailSectionPresentation.Layout.leadingIconFrame + 14)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
                .accessibilityIdentifier("RailFolderDetails")
        }
    }
}
