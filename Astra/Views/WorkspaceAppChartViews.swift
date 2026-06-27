import SwiftUI

/// Line and pie renderings for a Workspace App `chart` widget (widget `chartKind: line | pie`).
/// Bar charts stay in WorkspaceAppChartCard; these are the alternate kinds, kept in their own file
/// so the large detail-view owner doesn't grow. Both consume the same WorkspaceAppChartPresentation
/// the bar renderer uses — `fraction` is value/max (line y-axis) and `value` feeds pie proportions.
private let workspaceAppChartPalette: [Color] = [
    Stanford.lagunita, Stanford.paloAltoGreen, Stanford.poppy, Stanford.sky, Stanford.bay, Stanford.cardinalRed
]

struct WorkspaceAppLineChart: View {
    let chart: WorkspaceAppChartPresentation

    var body: some View {
        let points = chart.bars
        let segments = max(points.count - 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: width, y: height))
                    }
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)

                    Path { path in
                        for (index, bar) in points.enumerated() {
                            let dot = point(index, bar.fraction, width: width, height: height, segments: segments)
                            if index == 0 { path.move(to: dot) } else { path.addLine(to: dot) }
                        }
                    }
                    .stroke(Stanford.lagunita.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    ForEach(Array(points.enumerated()), id: \.offset) { index, bar in
                        Circle()
                            .fill(Stanford.lagunita)
                            .frame(width: 5, height: 5)
                            .position(point(index, bar.fraction, width: width, height: height, segments: segments))
                    }
                }
            }
            .frame(height: 110)

            HStack(spacing: 0) {
                ForEach(points) { bar in
                    Text(bar.label)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func point(_ index: Int, _ fraction: Double, width: CGFloat, height: CGFloat, segments: Int) -> CGPoint {
        CGPoint(x: width * CGFloat(index) / CGFloat(segments), y: height * (1 - CGFloat(fraction)))
    }
}

struct WorkspaceAppPieChart: View {
    let chart: WorkspaceAppChartPresentation

    var body: some View {
        let total = max(chart.bars.reduce(0) { $0 + $1.value }, 0.0001)
        HStack(alignment: .center, spacing: 14) {
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height)
                ZStack {
                    ForEach(Array(slices(total: total).enumerated()), id: \.offset) { index, slice in
                        Path { path in
                            let center = CGPoint(x: diameter / 2, y: diameter / 2)
                            path.move(to: center)
                            path.addArc(center: center, radius: diameter / 2,
                                        startAngle: slice.start, endAngle: slice.end, clockwise: false)
                            path.closeSubpath()
                        }
                        .fill(workspaceAppChartPalette[index % workspaceAppChartPalette.count].opacity(0.85))
                    }
                }
                .frame(width: diameter, height: diameter)
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(chart.bars.enumerated()), id: \.offset) { index, bar in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(workspaceAppChartPalette[index % workspaceAppChartPalette.count].opacity(0.85))
                            .frame(width: 8, height: 8)
                        Text(bar.label)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(bar.displayValue)
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func slices(total: Double) -> [(start: Angle, end: Angle)] {
        var result: [(start: Angle, end: Angle)] = []
        var cursor = -90.0  // start at 12 o'clock
        for bar in chart.bars {
            let sweep = bar.value / total * 360
            result.append((Angle(degrees: cursor), Angle(degrees: cursor + sweep)))
            cursor += sweep
        }
        return result
    }
}
