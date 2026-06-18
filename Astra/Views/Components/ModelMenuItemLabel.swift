import SwiftUI

/// Menu row label for a model choice: readable family/version first, provider
/// metadata next, and the exact `--model` value kept visible underneath.
struct ModelMenuItemLabel: View {
    let presentation: RuntimeModelMenuOptionPresentation
    let isSelected: Bool

    init(presentation: RuntimeModelMenuOptionPresentation, isSelected: Bool) {
        self.presentation = presentation
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}
