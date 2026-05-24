import SwiftUI

enum AstraToolbarCommandMetrics {
    static let clusterSpacing: CGFloat = 2
    static let clusterHorizontalPadding: CGFloat = 4
    static let clusterVerticalPadding: CGFloat = 3
    static let contextClusterSize: CGFloat = 34
    static let iconWidth: CGFloat = 30
    static let controlHeight: CGFloat = 28
    static let iconFontSize: CGFloat = 16
    static let labelIconFontSize: CGFloat = 15
    static let labelFontSize: CGFloat = 11
    static let menuChevronFontSize: CGFloat = 7
    static let labelSpacing: CGFloat = 5
    static let labelHorizontalPadding: CGFloat = 8
    static let activeFillOpacity: CGFloat = 0.12
    static let lightChromeFillOpacity: CGFloat = 0.58
    static let darkChromeFillOpacity: CGFloat = 0.07
    static let chromeStrokeOpacity: CGFloat = 0.10
}

struct AstraToolbarCommandCluster<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: AstraToolbarCommandMetrics.clusterSpacing) {
            content()
        }
        .padding(.horizontal, AstraToolbarCommandMetrics.clusterHorizontalPadding)
        .padding(.vertical, AstraToolbarCommandMetrics.clusterVerticalPadding)
        .background(chromeFill, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(AstraToolbarCommandMetrics.chromeStrokeOpacity), lineWidth: 1)
        )
    }

    private var chromeFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(AstraToolbarCommandMetrics.darkChromeFillOpacity)
            : Color.white.opacity(AstraToolbarCommandMetrics.lightChromeFillOpacity)
    }
}

struct AstraToolbarContextCommandCluster<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .frame(
            width: AstraToolbarCommandMetrics.contextClusterSize,
            height: AstraToolbarCommandMetrics.contextClusterSize
        )
        .background(chromeFill, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(AstraToolbarCommandMetrics.chromeStrokeOpacity), lineWidth: 1)
        )
    }

    private var chromeFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(AstraToolbarCommandMetrics.darkChromeFillOpacity)
            : Color.white.opacity(AstraToolbarCommandMetrics.lightChromeFillOpacity)
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
            .background {
                if isActive {
                    Capsule()
                        .fill(Stanford.lagunita.opacity(AstraToolbarCommandMetrics.activeFillOpacity))
                }
            }
            .contentShape(Rectangle())
    }
}

struct AstraToolbarCommandLabel: View {
    let systemImage: String
    let text: String
    var isActive = false
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: AstraToolbarCommandMetrics.labelSpacing) {
            Image(systemName: systemImage)
                .font(Stanford.ui(AstraToolbarCommandMetrics.labelIconFontSize, weight: .medium))
            Text(text)
                .font(Stanford.ui(AstraToolbarCommandMetrics.labelFontSize, weight: .semibold))
                .lineLimit(1)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(Stanford.ui(AstraToolbarCommandMetrics.menuChevronFontSize, weight: .bold))
                    .opacity(0.68)
            }
        }
        .foregroundStyle(isActive ? Stanford.lagunita : Color.primary)
        .padding(.horizontal, AstraToolbarCommandMetrics.labelHorizontalPadding)
        .frame(height: AstraToolbarCommandMetrics.controlHeight)
        .background {
            if isActive {
                Capsule()
                    .fill(Stanford.lagunita.opacity(AstraToolbarCommandMetrics.activeFillOpacity))
            }
        }
        .contentShape(Rectangle())
    }
}
