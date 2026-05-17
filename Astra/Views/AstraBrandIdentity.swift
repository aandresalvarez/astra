import SwiftUI

enum AstraReticleVariant {
    case standard
    case bold

    var inset: CGFloat {
        switch self {
        case .standard: 24
        case .bold: 20
        }
    }

    var thickness: CGFloat {
        switch self {
        case .standard: 18
        case .bold: 24
        }
    }

    var arm: CGFloat {
        switch self {
        case .standard: 46
        case .bold: 52
        }
    }

    var centerSize: CGFloat {
        switch self {
        case .standard: 28
        case .bold: 30
        }
    }
}

struct AstraReticleShape: Shape {
    var variant: AstraReticleVariant = .standard

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let scale = side / 200

        func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + x * scale,
                y: origin.y + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        let inset = variant.inset
        let thickness = variant.thickness
        let arm = variant.arm
        let far = 200 - inset

        var path = Path()
        let brackets = [
            scaledRect(x: inset, y: inset, width: arm, height: thickness),
            scaledRect(x: inset, y: inset, width: thickness, height: arm),
            scaledRect(x: far - arm, y: inset, width: arm, height: thickness),
            scaledRect(x: far - thickness, y: inset, width: thickness, height: arm),
            scaledRect(x: inset, y: far - thickness, width: arm, height: thickness),
            scaledRect(x: inset, y: far - arm, width: thickness, height: arm),
            scaledRect(x: far - arm, y: far - thickness, width: arm, height: thickness),
            scaledRect(x: far - thickness, y: far - arm, width: thickness, height: arm)
        ]
        brackets.forEach { path.addRect($0) }

        let center = CGPoint(x: origin.x + 100 * scale, y: origin.y + 100 * scale)
        let centerSize = variant.centerSize * scale
        path.move(to: CGPoint(x: center.x, y: center.y - centerSize))
        path.addLine(to: CGPoint(x: center.x + centerSize, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + centerSize))
        path.addLine(to: CGPoint(x: center.x - centerSize, y: center.y))
        path.closeSubpath()

        return path
    }
}

struct AstraReticleMark: View {
    var variant: AstraReticleVariant = .standard
    var color: Color = Stanford.cardinalRed

    var body: some View {
        AstraReticleShape(variant: variant)
            .fill(color)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct AstraAppIconTile: View {
    var size: CGFloat
    var variant: AstraReticleVariant = .standard
    var showsChannelBadge = AppChannel.current == .development

    private var backgroundColor: Color {
        showsChannelBadge ? Color(hex: 0x6E0F0F) : Color(hex: 0x8C1515)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.07), location: 0),
                            .init(color: .white.opacity(0.0), location: 0.38),
                            .init(color: .black.opacity(0.08), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
                }

            AstraReticleMark(variant: variant, color: Color(hex: Stanford.warmCanvasLightHex))
                .padding(size * 0.10)

            if showsChannelBadge {
                AstraDevBadge(size: size * 0.34)
                    .padding(size * 0.067)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AppChannel.current.displayName)
    }
}

private struct AstraDevBadge: View {
    var size: CGFloat

    var body: some View {
        Text("DEV")
            .font(Stanford.mono(max(size * 0.26, 8)).weight(.semibold))
            .foregroundStyle(Color(hex: 0xE7E1D8))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: size, height: size * 0.40)
            .background(Color(hex: 0x1F1E1B))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.10, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 1)
    }
}
