import SwiftUI

struct WorkspaceConceptPrimer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(Stanford.ui(14, weight: .semibold))
                .foregroundStyle(Stanford.interactive)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(WorkspaceCreationPresentation.primerTitle)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.readingText)

                Text(WorkspaceCreationPresentation.primerDescription)
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Stanford.interactive.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
