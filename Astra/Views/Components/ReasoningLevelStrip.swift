import SwiftUI

/// Geometry of the reasoning bars, pure so hit-testing and heights are testable.
enum ReasoningBarsGeometry {
    static let barWidth: CGFloat = 9
    static let barSpacing: CGFloat = 3
    static let minBarHeight: CGFloat = 6
    static let maxBarHeight: CGFloat = 20

    static func width(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * barWidth + CGFloat(count - 1) * barSpacing
    }

    /// Bars climb evenly from the shortest to the tallest; a lone bar is full height.
    static func height(at index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return maxBarHeight }
        let step = (maxBarHeight - minBarHeight) / CGFloat(count - 1)
        return minBarHeight + step * CGFloat(index)
    }

    /// The level an arrow key or an assistive "adjust" lands on, or nil at an
    /// end. With nothing selected there is no level to step from, so either
    /// direction starts at the first entry (the provider default) and the
    /// control can always be set.
    static func adjusted(from selected: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selected else { return 0 }
        let target = selected + delta
        return (0..<count).contains(target) ? target : nil
    }

    /// An index that may be stale (a hover or drag kept across a change in the
    /// model's levels), kept only if it still names a bar.
    static func valid(_ index: Int?, count: Int) -> Int? {
        guard let index, (0..<count).contains(index) else { return nil }
        return index
    }

    /// The bar a horizontal position falls on. The gap after a bar belongs to
    /// it, and positions past either end clamp to the nearest bar.
    static func index(atX x: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let pitch = barWidth + barSpacing
        return max(0, min(count - 1, Int((x / pitch).rounded(.down))))
    }
}

/// The reasoning-level control in the model selector's foot: one bar per level,
/// rising like a signal meter and filled up to the current level, with that
/// level's name beside it. Hovering a bar previews its name; clicking or
/// dragging across the bars picks, applying once when the drag ends. It is as
/// tall as the row it replaces, so every level shows without changing the
/// selector's size.
struct ReasoningLevelStrip: View {
    let choices: [ModelSelectorReasoningChoice]
    let onPick: (ModelSelectorReasoningChoice) -> Void

    @State private var hoverIndex: Int?
    @State private var dragIndex: Int?

    private let rowHeight: CGFloat = 28

    private var selectedIndex: Int? {
        choices.firstIndex(where: \.isSelected)
    }

    /// What the bars show: the level being dragged to, else the chosen one.
    private var shownIndex: Int? {
        ReasoningBarsGeometry.valid(dragIndex, count: choices.count) ?? selectedIndex
    }

    /// What the name shows: a drag or hover preview wins over the chosen level.
    private var namedIndex: Int? {
        ReasoningBarsGeometry.valid(dragIndex, count: choices.count)
            ?? ReasoningBarsGeometry.valid(hoverIndex, count: choices.count)
            ?? selectedIndex
    }

    var body: some View {
        HStack(spacing: 10) {
            bars
            nameLabel
        }
        .focusable()
        .onKeyPress(.leftArrow) { adjust(by: -1) }
        .onKeyPress(.rightArrow) { adjust(by: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning level")
        .accessibilityValue(selectedIndex.map { choices[$0].title } ?? "Not set")
        .accessibilityAdjustableAction { direction in
            _ = adjust(by: direction == .increment ? 1 : -1)
        }
    }

    /// Steps the level for the arrow keys and VoiceOver. Handled only when it
    /// moved, so an arrow at an end still reaches whatever sits beside it.
    private func adjust(by delta: Int) -> KeyPress.Result {
        guard let target = ReasoningBarsGeometry.adjusted(
            from: selectedIndex, by: delta, count: choices.count
        ) else { return .ignored }
        onPick(choices[target])
        return .handled
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: ReasoningBarsGeometry.barSpacing) {
            ForEach(choices.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(fill(for: index))
                    .frame(
                        width: ReasoningBarsGeometry.barWidth,
                        height: ReasoningBarsGeometry.height(at: index, count: choices.count)
                    )
            }
        }
        .frame(height: ReasoningBarsGeometry.maxBarHeight, alignment: .bottom)
        .frame(width: ReasoningBarsGeometry.width(count: choices.count), height: rowHeight)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: shownIndex)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverIndex = ReasoningBarsGeometry.index(atX: location.x, count: choices.count)
            case .ended:
                hoverIndex = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragIndex = ReasoningBarsGeometry.index(atX: value.location.x, count: choices.count)
                }
                .onEnded { value in
                    let index = ReasoningBarsGeometry.index(atX: value.location.x, count: choices.count)
                    dragIndex = nil
                    guard choices.indices.contains(index), !choices[index].isSelected else { return }
                    onPick(choices[index])
                }
        )
    }

    private func fill(for index: Int) -> Color {
        if let shownIndex, index <= shownIndex {
            return Stanford.lagunita
        }
        return Color.primary.opacity(index == hoverIndex ? 0.38 : 0.18)
    }

    /// Every title is laid out invisibly so the name never changes the row's
    /// width as it follows the selection.
    private var nameLabel: some View {
        ZStack(alignment: .leading) {
            ForEach(choices) { choice in
                Text(choice.title).hidden()
            }
            Text(namedIndex.map { choices[$0].title } ?? "")
                .foregroundStyle(Color.primary)
        }
        .font(Stanford.ui(12, weight: .medium))
        .lineLimit(1)
    }
}
