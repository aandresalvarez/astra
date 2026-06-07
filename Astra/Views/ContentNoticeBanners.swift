import SwiftUI

/// Top-of-window notice banners (recovery, external-route, and update notices).
/// Extracted from `ContentView` to keep that owner file focused; only
/// `TopNoticeBannersView` is referenced externally — the individual banner views
/// stay file-private here.
struct TopNoticeBannersView: View {
    let recoveryNotice: String
    let updateBlockNotice: String?
    let externalRouteNotice: String
    let onDismissRecoveryNotice: () -> Void
    let onDismissExternalRouteNotice: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        if !recoveryNotice.isEmpty || updateBlockNotice != nil || !externalRouteNotice.isEmpty {
            VStack(spacing: 0) {
                if !recoveryNotice.isEmpty {
                    RecoveryNoticeBanner(
                        message: recoveryNotice,
                        onDismiss: onDismissRecoveryNotice
                    )
                }
                if !externalRouteNotice.isEmpty {
                    ExternalRouteNoticeBanner(
                        message: externalRouteNotice,
                        onDismiss: onDismissExternalRouteNotice
                    )
                }
                if let updateBlockNotice {
                    UpdateNoticeBanner(
                        message: updateBlockNotice,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
        }
    }
}

private struct RecoveryNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "externaldrive.badge.checkmark",
            imageColor: Stanford.paloAltoGreen,
            message: message,
            buttonTitle: "Dismiss",
            buttonAction: onDismiss
        )
    }
}

private struct ExternalRouteNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "exclamationmark.triangle.fill",
            imageColor: Stanford.poppy,
            message: message,
            buttonTitle: "Dismiss",
            buttonAction: onDismiss
        )
    }
}

private struct UpdateNoticeBanner: View {
    let message: String
    let onCheckForUpdates: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "arrow.down.circle",
            imageColor: Stanford.cardinalRed,
            message: message,
            buttonTitle: "Check Again",
            buttonAction: onCheckForUpdates
        )
    }
}

private struct NoticeBanner: View {
    let systemImage: String
    let imageColor: Color
    let message: String
    let buttonTitle: String
    let buttonAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(imageColor)
            Text(message)
                .font(Stanford.body(13))
                .foregroundStyle(Stanford.black)
            Spacer()
            Button(buttonTitle, action: buttonAction)
                .font(Stanford.body(12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Stanford.fog)
        .overlay(alignment: .bottom) {
            SoftHorizontalTransition(height: 12)
                .rotationEffect(.degrees(180))
                .offset(y: 8)
        }
    }
}
