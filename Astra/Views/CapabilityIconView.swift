import AppKit
import SwiftUI

struct CapabilityIconView: View {
    let presentation: CapabilityIconPresentation
    let size: CGFloat
    let color: Color
    var weight: Font.Weight = .medium

    var body: some View {
        switch presentation.kind {
        case .systemSymbol(let name):
            Image(systemName: name)
                .font(Stanford.ui(size, weight: weight))
                .foregroundStyle(color)
        case .brand(.github):
            GitHubMarkShape()
                .fill(color)
                .frame(width: size, height: size)
        case .brand(.jira):
            JiraMarkShape()
                .fill(color)
                .frame(width: size, height: size)
        case .brand(.googleDrive):
            GoogleDriveMarkShape()
                .fill(color)
                .frame(width: size, height: size)
        case .brand(.googleCloud):
            GoogleCloudMarkShape()
                .fill(color)
                .frame(width: size, height: size)
        case .brand(.microsoft365):
            Microsoft365MarkShape()
                .fill(color)
                .frame(width: size, height: size)
        case .asset(let url):
            if let image = templateImage(contentsOf: url) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: presentation.fallbackSystemName)
                    .font(Stanford.ui(size, weight: weight))
                    .foregroundStyle(color)
            }
        }
    }

    private func templateImage(contentsOf url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

private struct GitHubMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 16
        let origin = CGPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        path.move(to: p(8, 0))
        path.addCurve(to: p(0, 8), control1: p(3.58, 0), control2: p(0, 3.58))
        path.addCurve(to: p(5.47, 15.59), control1: p(0, 11.54), control2: p(2.29, 14.53))
        path.addCurve(to: p(6.02, 15.21), control1: p(5.87, 15.66), control2: p(6.02, 15.42))
        path.addCurve(to: p(6.01, 13.72), control1: p(6.02, 15.02), control2: p(6.01, 14.39))
        path.addCurve(to: p(3.32, 12.78), control1: p(4.0, 14.09), control2: p(3.48, 13.23))
        path.addCurve(to: p(2.5, 11.65), control1: p(3.23, 12.55), control2: p(2.84, 11.84))
        path.addCurve(to: p(2.49, 11.12), control1: p(2.22, 11.5), control2: p(1.82, 11.13))
        path.addCurve(to: p(3.72, 11.94), control1: p(3.12, 11.11), control2: p(3.57, 11.7))
        path.addCurve(to: p(6.05, 12.6), control1: p(4.44, 13.15), control2: p(5.59, 12.81))
        path.addCurve(to: p(6.56, 11.53), control1: p(6.12, 12.08), control2: p(6.33, 11.73))
        path.addCurve(to: p(2.92, 7.58), control1: p(4.78, 11.33), control2: p(2.92, 10.64))
        path.addCurve(to: p(3.74, 5.43), control1: p(2.92, 6.71), control2: p(3.23, 5.99))
        path.addCurve(to: p(3.82, 3.31), control1: p(3.66, 5.23), control2: p(3.38, 4.41))
        path.addCurve(to: p(6.02, 4.13), control1: p(3.82, 3.31), control2: p(4.49, 3.1))
        path.addCurve(to: p(8.02, 3.86), control1: p(6.66, 3.95), control2: p(7.34, 3.86))
        path.addCurve(to: p(10.02, 4.13), control1: p(8.7, 3.86), control2: p(9.38, 3.95))
        path.addCurve(to: p(12.22, 3.31), control1: p(11.55, 3.09), control2: p(12.22, 3.31))
        path.addCurve(to: p(12.3, 5.43), control1: p(12.66, 4.41), control2: p(12.38, 5.23))
        path.addCurve(to: p(13.12, 7.58), control1: p(12.81, 5.99), control2: p(13.12, 6.7))
        path.addCurve(to: p(9.47, 11.53), control1: p(13.12, 10.65), control2: p(11.25, 11.33))
        path.addCurve(to: p(10.01, 13.01), control1: p(9.76, 11.78), control2: p(10.01, 12.26))
        path.addCurve(to: p(10, 15.21), control1: p(10.01, 14.08), control2: p(10, 14.94))
        path.addCurve(to: p(10.55, 15.59), control1: p(10, 15.42), control2: p(10.15, 15.67))
        path.addCurve(to: p(16, 8), control1: p(13.73, 14.53), control2: p(16, 11.54))
        path.addCurve(to: p(8, 0), control1: p(16, 3.58), control2: p(12.42, 0))
        path.closeSubpath()
        return path
    }
}

private struct JiraMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + x * side,
                y: origin.y + y * side,
                width: width * side,
                height: height * side
            )
        }

        var path = Path()
        path.addRoundedRect(
            in: r(0.08, 0.36, 0.55, 0.28),
            cornerSize: CGSize(width: side * 0.08, height: side * 0.08),
            style: .continuous
        )
        path.addRoundedRect(
            in: r(0.37, 0.36, 0.55, 0.28),
            cornerSize: CGSize(width: side * 0.08, height: side * 0.08),
            style: .continuous
        )
        return path
            .applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
            .applying(CGAffineTransform(rotationAngle: .pi / 4))
            .applying(CGAffineTransform(translationX: rect.midX, y: rect.midY))
    }
}

private struct GoogleDriveMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }

        var path = Path()
        path.move(to: p(0.43, 0.06))
        path.addLine(to: p(0.63, 0.06))
        path.addLine(to: p(0.96, 0.66))
        path.addLine(to: p(0.75, 0.66))
        path.addLine(to: p(0.53, 0.28))
        path.addLine(to: p(0.31, 0.66))
        path.addLine(to: p(0.08, 0.66))
        path.closeSubpath()
        path.move(to: p(0.08, 0.70))
        path.addLine(to: p(0.32, 0.70))
        path.addLine(to: p(0.20, 0.92))
        path.closeSubpath()
        path.move(to: p(0.35, 0.70))
        path.addLine(to: p(0.75, 0.70))
        path.addLine(to: p(0.87, 0.92))
        path.addLine(to: p(0.23, 0.92))
        path.closeSubpath()
        return path
    }
}

private struct GoogleCloudMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + x * side,
                y: origin.y + y * side,
                width: width * side,
                height: height * side
            )
        }

        var path = Path()
        path.addEllipse(in: r(0.15, 0.42, 0.26, 0.26))
        path.addEllipse(in: r(0.33, 0.24, 0.34, 0.34))
        path.addEllipse(in: r(0.57, 0.39, 0.30, 0.30))
        path.addRoundedRect(
            in: r(0.22, 0.52, 0.56, 0.23),
            cornerSize: CGSize(width: side * 0.11, height: side * 0.11)
        )
        return path
    }
}

private struct Microsoft365MarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }

        var path = Path()
        path.move(to: p(0.50, 0.05))
        path.addLine(to: p(0.88, 0.25))
        path.addLine(to: p(0.88, 0.75))
        path.addLine(to: p(0.50, 0.95))
        path.addLine(to: p(0.12, 0.75))
        path.addLine(to: p(0.12, 0.25))
        path.closeSubpath()
        path.move(to: p(0.32, 0.31))
        path.addLine(to: p(0.50, 0.22))
        path.addLine(to: p(0.68, 0.31))
        path.addLine(to: p(0.68, 0.69))
        path.addLine(to: p(0.50, 0.78))
        path.addLine(to: p(0.32, 0.69))
        path.closeSubpath()
        return path
    }
}
