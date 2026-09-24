import SwiftUI

/// One chrome system for every shelf panel (Files, Query, Browser).
///
/// Surfaces: the shelf container paints `.bar` once (`ContentView`). Toolbars,
/// tab strips, docked navigators, and status bars sit on it with no fill of
/// their own, separated by `Divider()`; only a pane floating over content
/// repeats the material, as `floatingSurface`. Documents, editors, and
/// results use `contentSurface`; cards inside them use `raisedSurface`.
/// Interaction fills come from Stanford's fill scale and borders from its
/// stroke scale, so a control reads the same in every shelf.
enum ShelfChrome {
    static let toolbarHeight: CGFloat = 42
    static let tabStripHeight: CGFloat = 40
    static let barHorizontalPadding: CGFloat = 12
    static let controlSize: CGFloat = 28
    static let controlRadius = Stanford.radiusSmall
    static let disabledOpacity = 0.42
    static let contentSurface = Stanford.cardBackground.opacity(0.45)
    static let raisedSurface = Stanford.cardBackground
    /// A pane that floats over shelf content (the unpinned file navigator)
    /// carries its own material, since it covers the document beneath it.
    static let floatingSurface: Material = .bar
}

/// Toolbar icon (or short label) button, shared by every shelf toolbar.
/// `isActive` marks a toggle that is on.
struct ShelfToolbarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ShelfToolbarButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct ShelfToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfChrome.controlRadius, style: .continuous)
        configuration.label
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle((isActive ? Stanford.lagunita : Color.primary).opacity(configuration.isPressed ? 0.55 : (isActive ? 1 : 0.82)))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: ShelfChrome.controlSize, minHeight: ShelfChrome.controlSize)
            .background(shape.fill(fill))
            .overlay(shape.stroke(isActive ? Stanford.lagunita.opacity(Stanford.strokeActive) : .clear, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : ShelfChrome.disabledOpacity)
            .onHover { isHovered = isEnabled && $0 }
    }

    private var fill: Color {
        if isActive {
            return Stanford.lagunita.opacity(configuration.isPressed ? Stanford.fillTintPressed : Stanford.fillTint)
        }
        if configuration.isPressed { return Color.primary.opacity(Stanford.fillPressed) }
        return isHovered ? Color.primary.opacity(Stanford.fillSoft) : .clear
    }
}

/// Soft text button for shelf bars and workflow cards; `isPrimary` is the one
/// accent-filled action in a bar.
struct ShelfSoftButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfChrome.controlRadius, style: .continuous)
        configuration.label
            .font(Stanford.ui(12, weight: .semibold))
            .foregroundStyle(isPrimary ? Color.white : Color.primary.opacity(isEnabled ? 0.82 : 0.45))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(shape.fill(fill(isPressed: configuration.isPressed)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : ShelfChrome.disabledOpacity)
    }

    private func fill(isPressed: Bool) -> Color {
        if isPrimary {
            return Stanford.lagunita.opacity(isPressed ? 0.82 : 1)
        }
        return Color.primary.opacity(isPressed ? Stanford.fillPressed : Stanford.fillSoft)
    }
}

/// The horizontally scrolling strip of open documents at the top of a shelf.
struct ShelfTabStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .frame(height: ShelfChrome.tabStripHeight)
    }
}

/// One open document in a `ShelfTabStrip`. The Files and Query shelves share
/// it, so the selected tab reads the same (content surface plus a lagunita
/// underline) in both.
struct ShelfDocumentTab: View {
    let title: String
    let systemImage: String
    let help: String
    let isSelected: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(Stanford.ui(11, weight: .semibold))
                    Text(title)
                        .font(Stanford.ui(12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isDirty {
                        Circle()
                            .fill(Stanford.cardinalRed)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                .foregroundStyle(isSelected ? Stanford.black : Stanford.coolGrey)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.black.opacity(0.75) : Stanford.coolGrey.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close \(title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 34)
        .background(isSelected ? ShelfChrome.contentSurface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Stanford.lagunita : Color.clear)
                .frame(height: 2)
        }
    }
}
