import SwiftUI

/// The open folder has a forward flap; color and selection are independent.
struct WorkspaceFolderIcon: View {
    let isExpanded: Bool

    var body: some View {
        Group {
            if isExpanded {
                GeometryReader { geometry in
                    Self.openFolderPath(size: geometry.size)
                        .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 17, height: 14)
            } else {
                Image(systemName: "folder")
            }
        }
        .accessibilityHidden(true)
    }

    static func openFolderPath(size: CGSize) -> Path {
        Path { path in
            let w = size.width
            let h = size.height
            path.move(to: CGPoint(x: w * 0.08, y: h * 0.82))
            path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.18))
            path.addQuadCurve(to: CGPoint(x: w * 0.18, y: h * 0.1), control: CGPoint(x: w * 0.08, y: h * 0.1))
            for point in [
                CGPoint(x: w * 0.4, y: h * 0.1), CGPoint(x: w * 0.51, y: h * 0.27),
                CGPoint(x: w * 0.83, y: h * 0.27), CGPoint(x: w * 0.83, y: h * 0.43)
            ] { path.addLine(to: point) }
            path.move(to: CGPoint(x: w * 0.08, y: h * 0.88))
            for point in [
                CGPoint(x: w * 0.27, y: h * 0.43), CGPoint(x: w * 0.96, y: h * 0.43),
                CGPoint(x: w * 0.77, y: h * 0.88)
            ] { path.addLine(to: point) }
            path.closeSubpath()
        }
    }
}
