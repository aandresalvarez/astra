import SwiftUI

/// Every folder has a stable scan row; the shared folder editor mounts once.
struct RailFolderRows<Details: View>: View {
    let rows: [WorkspaceRailSectionPresentation.Row]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onChoosePrimary: () -> Void
    @ViewBuilder var details: () -> Details

    var body: some View {
        ForEach(rows) { row in
            RailKeyValueRow(row: row, isExpanded: isExpanded, help: row.representedPath,
                            onTap: { activate(row) }, onAction: { activate(row) })
        }
        if !rows.isEmpty, isExpanded {
            details()
                .padding(.leading, WorkspaceRailSectionPresentation.Layout.leadingIconFrame + 14)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
                .accessibilityIdentifier("RailFolderDetails")
        }
    }

    func activate(_ row: WorkspaceRailSectionPresentation.Row) {
        if row.representedPath == nil { onChoosePrimary() } else { onToggle() }
    }
}
