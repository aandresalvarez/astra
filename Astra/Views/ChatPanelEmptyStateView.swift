import SwiftUI

struct ChatPanelEmptyStateView: View {
    let presentation: ChatPanelDraftPresentation
    let isThinking: Bool
    let onPrimaryAction: () -> Void

    var body: some View {
        if presentation.usesWorkspaceAppStudioEmptyState {
            appStudioDraftHero
        } else {
            genericHero
        }
    }

    private var genericHero: some View {
        VStack(spacing: 24) {
            AstraPulsingReticleMark(color: Color(hex: Stanford.cardinalRedLightHex))
                .frame(width: 76, height: 76)

            Text(presentation.heroTitle)
                .font(Stanford.heading(28))
                .foregroundStyle(Stanford.black)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .lineLimit(2)
                .frame(maxWidth: 720, minHeight: 84)

            HStack(spacing: 28) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(Stanford.ui(13))
                    Text("Enter to run immediately")
                        .font(Stanford.body(15))
                }
                .foregroundStyle(Stanford.lagunita)

                HStack(spacing: 5) {
                    Image(systemName: "switch.2")
                        .font(Stanford.ui(13))
                    Text("Enable Goal mode to refine first")
                        .font(Stanford.body(15))
                }
                .foregroundStyle(Color.primary.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appStudioDraftHero: some View {
        VStack(spacing: 18) {
            Image(systemName: "plus.app")
                .font(Stanford.ui(34, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 72, height: 72)
                .background(Stanford.lagunita.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
                )

            VStack(spacing: 8) {
                Text(presentation.heroTitle)
                    .font(Stanford.heading(28))
                    .foregroundStyle(Stanford.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .lineLimit(2)

                Text(presentation.heroSubtitle)
                    .font(Stanford.body(15))
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 620)
            }

            HStack(spacing: 18) {
                contextBadge(icon: "doc.text.magnifyingglass", title: "Context attached")
                contextBadge(icon: "rectangle.3.group", title: "Plan first")
                contextBadge(icon: "shield.checkered", title: "Permission-aware")
            }

            Button(action: onPrimaryAction) {
                Label(presentation.primaryActionTitle, systemImage: "sparkles")
                    .font(Stanford.body(15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Stanford.lagunita)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isThinking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contextBadge(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(Stanford.caption(13).weight(.semibold))
            .foregroundStyle(Stanford.coolGrey)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Stanford.fog.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
