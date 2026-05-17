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
    var focusProgress: CGFloat = 0

    var animatableData: CGFloat {
        get { focusProgress }
        set { focusProgress = newValue }
    }

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
        let focusOffset = focusProgress * 24
        let far = 200 - inset

        var path = Path()
        let brackets = [
            scaledRect(x: inset + focusOffset, y: inset + focusOffset, width: arm, height: thickness),
            scaledRect(x: inset + focusOffset, y: inset + focusOffset, width: thickness, height: arm),
            scaledRect(x: far - arm - focusOffset, y: inset + focusOffset, width: arm, height: thickness),
            scaledRect(x: far - thickness - focusOffset, y: inset + focusOffset, width: thickness, height: arm),
            scaledRect(x: inset + focusOffset, y: far - thickness - focusOffset, width: arm, height: thickness),
            scaledRect(x: inset + focusOffset, y: far - arm - focusOffset, width: thickness, height: arm),
            scaledRect(x: far - arm - focusOffset, y: far - thickness - focusOffset, width: arm, height: thickness),
            scaledRect(x: far - thickness - focusOffset, y: far - arm - focusOffset, width: thickness, height: arm)
        ]
        brackets.forEach { path.addRect($0) }

        let center = CGPoint(x: origin.x + 100 * scale, y: origin.y + 100 * scale)
        let centerSize = variant.centerSize * (1 + focusProgress * 0.08) * scale
        path.move(to: CGPoint(x: center.x, y: center.y - centerSize))
        path.addLine(to: CGPoint(x: center.x + centerSize, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + centerSize))
        path.addLine(to: CGPoint(x: center.x - centerSize, y: center.y))
        path.closeSubpath()

        return path
    }
}

struct AstraPulsingReticleMark: View {
    var variant: AstraReticleVariant = .standard
    var color: Color = Stanford.cardinalRed

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFocused = false

    var body: some View {
        AstraReticleShape(variant: variant, focusProgress: reduceMotion ? 0 : (isFocused ? 1 : 0))
            .fill(color)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                    isFocused = true
                }
            }
            .onDisappear {
                isFocused = false
            }
            .onChange(of: reduceMotion) {
                isFocused = !reduceMotion
            }
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
        Color(hex: Stanford.cardinalRedLightHex)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(backgroundColor)

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
