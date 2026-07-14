import SwiftUI

struct OnboardingProgressHeader: View {
    let currentStepIndex: Int
    let stepCount: Int
    let allowsDismiss: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 28) {
                Text("Setup")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(Stanford.readingText)

                Text("Step \(currentStepIndex + 1) of \(stepCount)")
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.textSecondary)

                Spacer(minLength: 0)

                if allowsDismiss {
                    Button("Close", action: onDismiss)
                        .font(Stanford.body(13))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close setup")
                }
            }

            HStack(spacing: 10) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStepIndex
                              ? Stanford.interactive
                              : Stanford.sandstone.opacity(0.34))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup, step \(currentStepIndex + 1) of \(stepCount)")
    }
}

struct OnboardingActionFooter: View {
    let showsBack: Bool
    let blocker: String?
    let warning: String?
    let requirement: String?
    let primaryActionTitle: String
    let guidance: OnboardingActionGuidance
    let isPrimaryActionEnabled: Bool
    let reduceMotion: Bool
    let onBack: () -> Void
    let onPrimaryAction: () -> Void

    @State private var isPrimaryActionHovered = false
    @FocusState private var isPrimaryActionFocused: Bool

    private var showsGuidance: Bool {
        isPrimaryActionHovered || isPrimaryActionFocused
    }

    var body: some View {
        HStack(spacing: 16) {
            if showsBack {
                Button("Back", action: onBack)
                    .font(Stanford.body(13))
            }

            footerMessage
                .frame(maxWidth: 560, alignment: .leading)

            Spacer(minLength: 20)

            Button(action: onPrimaryAction) {
                HStack(spacing: 8) {
                    Text(primaryActionTitle)
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(StanfordButtonStyle())
            .keyboardShortcut(.defaultAction)
            .focused($isPrimaryActionFocused)
            .disabled(!isPrimaryActionEnabled)
            .overlay {
                RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                    .stroke(
                        Stanford.sky.opacity(showsGuidance && isPrimaryActionEnabled ? 0.62 : 0),
                        lineWidth: 3
                    )
                    .padding(-4)
            }
            .shadow(
                color: Stanford.sky.opacity(showsGuidance && isPrimaryActionEnabled ? 0.24 : 0),
                radius: 7
            )
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    isPrimaryActionHovered = hovering
                }
            }
            .help(guidance.detail)
            .accessibilityIdentifier("OnboardingPrimaryAction")
            .accessibilityHint(guidance.detail)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(minHeight: 82)
    }

    @ViewBuilder
    private var footerMessage: some View {
        if let blocker {
            statusMessage(blocker, systemImage: "exclamationmark.triangle.fill", tint: Stanford.statusError)
        } else if let warning {
            statusMessage(warning, systemImage: "exclamationmark.triangle.fill", tint: Stanford.statusWarn)
        } else if let requirement {
            statusMessage(requirement, systemImage: "pencil.line", tint: Stanford.textSecondary)
        } else {
            guidanceMessage
                .opacity(showsGuidance ? 1 : 0.72)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsGuidance)
        }
    }

    private var guidanceMessage: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: guidance.systemImage)
                .font(Stanford.ui(18, weight: .medium))
                .foregroundStyle(Stanford.textSecondary)
                .frame(width: 28, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(guidance.title)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.readingText)
                Text(guidance.detail)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusMessage(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(Stanford.caption(11))
            .foregroundStyle(tint)
            .lineLimit(2)
    }
}
