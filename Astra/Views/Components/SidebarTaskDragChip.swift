import SwiftUI

/// The chip that follows the cursor while a sidebar task is dragged toward
/// the Pinned section. Was a thin material rectangle; it now sits on
/// `cardBackground` with a hairline border and a soft shadow so it reads as a
/// card lifted off the surface rather than a translucent overlay.
struct SidebarTaskDragChip: View {
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "pin.fill")
                .font(Stanford.ui(11, weight: .medium))
                .foregroundStyle(Stanford.poppy)
            Text(title)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(shape.fill(Stanford.cardBackground))
        .overlay(shape.strokeBorder(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
    }
}
