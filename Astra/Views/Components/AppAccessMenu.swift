import SwiftUI

struct AppAccessMenu: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsSnapshotStore
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("AppAccessMenuButton")
                .accessibilityLabel("ASTRA app menu")
                .help("Open ASTRA utilities")

                if appUpdateController.shouldShowUpdateButton {
                    AppAccessAvailableUpdateButton(appUpdateController: appUpdateController)
                }
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
            .onHover { isHovered = $0 }
        }
        .overlay(alignment: .top) {
            if isPresented {
                AppAccessAttachedDrawer(
                    appearanceToggle: AppearanceTogglePresentation.make(currentColorScheme: colorScheme),
                    appUpdateController: appUpdateController,
                    performDestination: perform,
                    performAppearanceToggle: toggleAppearance
                )
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
        AppAccessMenuPresentation.drawerRowCount(destinationCount: AppAccessDestination.allCases.count)
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

    private func toggleAppearance() {
        appSettings.setAppearance(AppearancePreference.toggled(from: colorScheme))
        dismiss()
    }
}

private struct AppAccessAvailableUpdateButton: View {
    @ObservedObject var appUpdateController: AppUpdateController

    var body: some View {
        Button(action: appUpdateController.checkForUpdatesFromButton) {
            Image(systemName: "arrow.down.to.line")
                .font(Stanford.ui(14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help(appUpdateController.statusMessage ?? "Install the available ASTRA update")
        .accessibilityIdentifier("AppAccessAvailableUpdateButton")
        .accessibilityLabel(appUpdateController.buttonTitle)
    }
}

private struct AppAccessAttachedDrawer: View {
    let appearanceToggle: AppearanceTogglePresentation
    @ObservedObject var appUpdateController: AppUpdateController
    let performDestination: (AppAccessDestination) -> Void
    let performAppearanceToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppAccessMenuPresentation.drawerRowSpacing) {
            ForEach(AppAccessDestination.allCases) { destination in
                AppAccessMenuItemButton(destination: destination, perform: performDestination)
            }

            AppAccessUpdateCheckButton(appUpdateController: appUpdateController)

            AppAccessAppearanceToggleButton(
                presentation: appearanceToggle,
                perform: performAppearanceToggle
            )
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

private struct AppAccessUpdateCheckButton: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @State private var isHovered = false

    var body: some View {
        Button {
            appUpdateController.checkForUpdates()
        } label: {
            AppAccessMenuActionRow(
                title: "Check for Updates…",
                systemImageName: "arrow.triangle.2.circlepath",
                isHovered: isHovered,
                isEnabled: appUpdateController.canCheckForUpdates
            )
        }
        .buttonStyle(.plain)
        .disabled(!appUpdateController.canCheckForUpdates)
        .onHover { isHovered = $0 }
        .help("Check for signed ASTRA updates")
        .accessibilityIdentifier("AppAccessMenuItem.checkForUpdates")
    }
}

private struct AppAccessAppearanceToggleButton: View {
    let presentation: AppearanceTogglePresentation
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            AppAccessMenuActionRow(
                title: presentation.title,
                systemImageName: presentation.systemImageName,
                isHovered: isHovered,
                isEnabled: true
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(presentation.helpText)
        .accessibilityIdentifier("AppAccessMenuItem.appearanceToggle")
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
        AppAccessMenuActionRow(
            title: destination.title,
            systemImageName: destination.systemImageName,
            isHovered: isHovered,
            isEnabled: true
        )
    }
}

private struct AppAccessMenuActionRow: View {
    let title: String
    let systemImageName: String
    let isHovered: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImageName)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(isEnabled ? Stanford.coolGrey : Stanford.coolGrey.opacity(0.4))
                .frame(width: 18)

            Text(title)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(isEnabled ? Stanford.black : Stanford.black.opacity(0.4))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: AppAccessMenuPresentation.drawerRowHeight, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .fill(isHovered && isEnabled ? Color.primary.opacity(0.055) : Color.clear)
        }
    }
}
