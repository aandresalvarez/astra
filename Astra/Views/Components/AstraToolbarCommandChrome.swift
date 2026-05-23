import SwiftUI

enum AstraToolbarCommandMetrics {
    static let clusterSpacing: CGFloat = 2
    static let clusterHorizontalPadding: CGFloat = 4
    static let clusterVerticalPadding: CGFloat = 3
    static let iconWidth: CGFloat = 30
    static let controlHeight: CGFloat = 28
    static let iconFontSize: CGFloat = 16
    static let labelIconFontSize: CGFloat = 15
    static let labelFontSize: CGFloat = 11
    static let labelSpacing: CGFloat = 5
    static let labelHorizontalPadding: CGFloat = 8
}

struct AstraToolbarCommandCluster<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: AstraToolbarCommandMetrics.clusterSpacing) {
            content()
        }
        .padding(.horizontal, AstraToolbarCommandMetrics.clusterHorizontalPadding)
        .padding(.vertical, AstraToolbarCommandMetrics.clusterVerticalPadding)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct AstraToolbarCommandIcon: View {
    let systemImage: String
    var isActive = false

    var body: some View {
        Image(systemName: systemImage)
            .font(Stanford.ui(AstraToolbarCommandMetrics.iconFontSize, weight: .medium))
            .foregroundStyle(isActive ? Stanford.lagunita : Color.primary)
            .frame(
                width: AstraToolbarCommandMetrics.iconWidth,
                height: AstraToolbarCommandMetrics.controlHeight
            )
            .contentShape(Rectangle())
    }
}

struct AstraToolbarCommandLabel: View {
    let systemImage: String
    let text: String
    var isActive = false

    var body: some View {
        HStack(spacing: AstraToolbarCommandMetrics.labelSpacing) {
            Image(systemName: systemImage)
                .font(Stanford.ui(AstraToolbarCommandMetrics.labelIconFontSize, weight: .medium))
            Text(text)
                .font(Stanford.ui(AstraToolbarCommandMetrics.labelFontSize, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? Stanford.lagunita : Color.primary)
        .padding(.horizontal, AstraToolbarCommandMetrics.labelHorizontalPadding)
        .frame(height: AstraToolbarCommandMetrics.controlHeight)
        .contentShape(Rectangle())
    }
}
