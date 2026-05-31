import SwiftUI

struct SidebarTaskTitleText: View {
    let presentation: Formatters.SidebarTaskTitlePresentation
    let font: Font

    private var primarySplit: (head: String, tail: String)? {
        let marker = " … "
        guard let range = presentation.primary.range(of: marker) else { return nil }
        return (
            String(presentation.primary[..<range.lowerBound]),
            String(presentation.primary[range.upperBound...])
        )
    }

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

            if let primarySplit {
                Text(primarySplit.head)
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text("…")
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(primarySplit.tail)
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(presentation.primary)
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
        }
        .help(presentation.fullTitle)
        .accessibilityLabel(presentation.fullTitle)
    }
}
