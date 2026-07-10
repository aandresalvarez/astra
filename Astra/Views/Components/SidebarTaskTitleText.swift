import SwiftUI
import ASTRAPersistence
import ASTRACore
import ASTRAModels

struct SidebarTaskTitleText: View {
    let presentation: Formatters.SidebarTaskTitlePresentation
    let font: Font
    /// Overrides the usual full-title tooltip when the containing row needs
    /// to surface a more useful piece of context on hover.
    var helpText: String?

    var body: some View {
        HStack(spacing: 4) {
            if let prefix = presentation.prefix {
                Text(prefix)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("·")
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(presentation.primary)
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .help(helpText ?? presentation.fullTitle)
        .accessibilityLabel(presentation.fullTitle)
        .accessibilityHint(helpText ?? "")
    }
}
