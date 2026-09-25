import SwiftUI

/// Below a finished answer, when the run said more than the answer shows (its
/// progress narration, an earlier draft): a disclosure that opens the full
/// response in place, rendered like the answer, and closes it again.
struct FullResponseDisclosureView: View {
    let fullText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                    Text(isExpanded ? "Hide full response" : "Show full response")
                        .font(Stanford.chatMeta(12))
                }
                .foregroundStyle(Stanford.lagunita)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded
                ? "Hides everything the agent wrote this turn"
                : "Shows everything the agent wrote this turn, not only the answer")

            if isExpanded {
                MarkdownTextView(text: fullText, isSelectable: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Stanford.separator)
                            .frame(width: 1)
                    }
            }
        }
    }
}
