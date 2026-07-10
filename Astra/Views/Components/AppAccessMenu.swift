import SwiftUI

struct AppAccessMenu: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(menuAnimation) {
                    isPresented.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AppAccessMenuPresentation.footerIconSystemName)
                        .font(Stanford.ui(14, weight: .medium))
                        .frame(width: 18)

                    Text(AppAccessMenuPresentation.footerMenuTitle)
                        .font(Stanford.ui(13, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up")
                        .font(Stanford.ui(9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isPresented ? 180 : 0))
                        .animation(menuAnimation, value: isPresented)
                }
                .foregroundStyle(Stanford.black)
                .padding(.horizontal, AppAccessMenuPresentation.footerContentHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: AppAccessMenuPresentation.footerMinimumHeight)
                .contentShape(Rectangle())
                .background {
                    // This intentionally fills the footer's rectangular bounds.
                    // The enclosing sidebar clips its bottom edge to the system
                    // rounded corner, avoiding a second, mismatched corner radius.
                    controlFill
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityIdentifier("AppAccessMenuButton")
            .accessibilityLabel("ASTRA app menu")
            .help("Open ASTRA utilities")
        }
        .overlay(alignment: .top) {
            if isPresented {
                AppAccessAttachedDrawer { destination in
                    perform(destination)
                }
                .frame(height: AppAccessMenuPresentation.drawerHeight(rowCount: drawerRowCount))
                .offset(y: -AppAccessMenuPresentation.drawerVerticalOffset(rowCount: drawerRowCount))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .onAppear { isPresented = false }
        .onExitCommand {
            dismiss()
        }
    }

    private var controlFill: Color {
        if isPresented {
            return Color.primary.opacity(AppAccessMenuPresentation.footerOpenFillOpacity)
        }
        let opacity = isHovered
            ? AppAccessMenuPresentation.footerHoverFillOpacity
            : AppAccessMenuPresentation.footerRestFillOpacity
        return Color.primary.opacity(opacity)
    }

    private var menuAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var drawerRowCount: Int {
        AppAccessDestination.allCases.count
    }

    private func perform(_ destination: AppAccessDestination) {
        dismiss()
        switch destination {
        case .settings:
            openSettings()
        case .logs:
            openWindow(id: AppWindowIDs.logs)
        case .usage:
            openWindow(id: AppWindowIDs.usage)
        }
    }

    private func dismiss() {
        withAnimation(menuAnimation) {
            isPresented = false
        }
    }
}

private struct AppAccessAttachedDrawer: View {
    let perform: (AppAccessDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppAccessMenuPresentation.drawerRowSpacing) {
            ForEach(AppAccessDestination.allCases) { destination in
                AppAccessMenuItemButton(destination: destination, perform: perform)
            }
        }
        .padding(AppAccessMenuPresentation.drawerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(Stanford.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .accessibilityIdentifier("AppAccessMenuDrawer")
    }
}

private struct AppAccessMenuItemButton: View {
    let destination: AppAccessDestination
    let perform: (AppAccessDestination) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            perform(destination)
        } label: {
            AppAccessMenuRow(destination: destination, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(destination.helpText)
        .accessibilityIdentifier("AppAccessMenuItem.\(destination.rawValue)")
    }
}

private struct AppAccessMenuRow: View {
    let destination: AppAccessDestination
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: destination.systemImageName)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 18)

            Text(destination.title)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(Stanford.black)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: AppAccessMenuPresentation.drawerRowHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.055) : Color.clear)
        }
    }
}
