import SwiftUI

enum MacOSPermissionCheckState: Equatable {
    case notChecked
    case checking
    case ready
    case needsAction(MacOSPermissionIssue)
    case unavailable(String)

    var statusText: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking"
        case .ready: "Ready"
        case .needsAction: "Needs permission"
        case .unavailable: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .notChecked: "circle.dotted"
        case .checking: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .needsAction: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notChecked, .checking: Stanford.coolGrey
        case .ready: Stanford.statusHealthy
        case .needsAction: Stanford.statusWarn
        case .unavailable: Stanford.statusError
        }
    }

    var message: String {
        switch self {
        case .notChecked:
            "Check before using browser control."
        case .checking:
            "Opening or attaching to the controlled browser..."
        case .ready:
            "ASTRA can open and control the browser."
        case .needsAction(let issue):
            issue.message
        case .unavailable(let detail):
            detail
        }
    }
}

@MainActor
final class MacOSPermissionsViewModel: ObservableObject {
    @Published private(set) var browserControlState: MacOSPermissionCheckState = .notChecked

    private let browser = ControlledBrowserController()
    private let appDisplayName: String

    init(appDisplayName: String = AppBuildInfo.current.displayName) {
        self.appDisplayName = appDisplayName
    }

    func checkBrowserControl() async {
        guard browserControlState != .checking else { return }
        browserControlState = .checking

        await browser.launch(initialAddress: "about:blank")

        if browser.isRunning {
            browserControlState = .ready
            return
        }

        if let issue = MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: appDisplayName,
            browserName: browser.browserName,
            isRunning: browser.isRunning,
            runState: browser.runState,
            lastErrorMessage: browser.lastErrorMessage
        ) {
            browserControlState = .needsAction(issue)
            return
        }

        browserControlState = .unavailable(browser.lastErrorMessage ?? browser.statusMessage)
    }

    func openSettings() {
        guard case .needsAction(let issue) = browserControlState else {
            MacOSPermissionDiagnostics.openSettings(for: .appManagement)
            return
        }
        MacOSPermissionDiagnostics.openSettings(for: issue.kind)
    }
}

struct MacOSPermissionsSectionView: View {
    enum Context {
        case onboarding
        case settings
    }

    @StateObject private var model: MacOSPermissionsViewModel
    private let context: Context

    init(context: Context, appDisplayName: String = AppBuildInfo.current.displayName) {
        self.context = context
        self._model = StateObject(wrappedValue: MacOSPermissionsViewModel(appDisplayName: appDisplayName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            permissionRow
            statusMessage
        }
        .padding(16)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(model.browserControlState.tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(Stanford.ui(21, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 38, height: 38)
                .background(Stanford.lagunita.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(context == .onboarding ? "Grant macOS Access" : "macOS Permissions")
                    .font(Stanford.heading(18))
                    .foregroundStyle(Stanford.black)
                Text("Verify the permission ASTRA needs for browser control.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text("Browser control")
                    .font(Stanford.body(14).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text("Lets ASTRA use the separate controlled browser for web tasks.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            statusPill

            Button {
                Task { await model.checkBrowserControl() }
            } label: {
                Label(checkButtonTitle, systemImage: "checkmark.seal")
                    .font(Stanford.caption(12).weight(.semibold))
            }
            .disabled(model.browserControlState == .checking)
        }
        .padding(12)
        .background(model.browserControlState.tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.browserControlState == .checking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: model.browserControlState.symbolName)
                .font(Stanford.ui(17, weight: .semibold))
                .foregroundStyle(model.browserControlState.tint)
                .frame(width: 22, height: 22)
        }
    }

    private var statusPill: some View {
        Text(model.browserControlState.statusText)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(model.browserControlState.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(model.browserControlState.tint.opacity(0.10))
            .clipShape(Capsule())
            .lineLimit(1)
    }

    @ViewBuilder
    private var statusMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: messageIcon)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(model.browserControlState.tint)
                .frame(width: 16)
                .padding(.top, 2)

            Text(model.browserControlState.message)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            if case .needsAction = model.browserControlState {
                Button {
                    model.openSettings()
                } label: {
                    Label("Open App Management", systemImage: "gearshape")
                        .font(Stanford.caption(12).weight(.semibold))
                }
            }
        }
        .padding(11)
        .background(model.browserControlState.tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var checkButtonTitle: String {
        switch model.browserControlState {
        case .notChecked: "Check"
        case .checking: "Checking"
        default: "Check Again"
        }
    }

    private var messageIcon: String {
        switch model.browserControlState {
        case .ready: "checkmark.circle.fill"
        case .needsAction, .unavailable: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }
}
