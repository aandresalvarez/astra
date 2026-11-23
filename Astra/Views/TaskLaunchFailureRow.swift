import SwiftUI

/// A turn ASTRA refused before any run existed. With no run there is no run
/// activity to carry the reason, so it is a line of the conversation itself.
/// Same quiet layout as the other system lines, with the failure icon.
struct TaskLaunchFailureRow: View {
    let text: String
    var count: Int = 1

    var body: some View {
        // `.top`, not `.firstTextBaseline`: the text is selectable, and a
        // baseline-aligned HStack live-locks on the selection overlay's
        // baseline query (see MarkdownTextView's list-item case).
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(11, weight: .medium))
                .foregroundStyle(Stanford.failed)
                .frame(width: 14)
                .padding(.top, 2)
            Text(text)
                .font(Stanford.chatMeta(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if count > 1 {
                Text("\u{00D7}\(count)")
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: Stanford.chatParagraphMaxWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 1 ? "Could not start, \(count) times: \(text)" : "Could not start: \(text)")
        .accessibilityIdentifier("TaskLaunchFailureRow")
    }
}
