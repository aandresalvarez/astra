import SwiftUI

struct SidebarTaskTitleText: View {
    let presentation: Formatters.SidebarTaskTitlePresentation
    let font: Font

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
        .help(presentation.fullTitle)
        .accessibilityLabel(presentation.fullTitle)
    }
}
