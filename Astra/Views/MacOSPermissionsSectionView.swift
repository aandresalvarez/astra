import SwiftUI

enum MacOSPermissionCheckID: String, CaseIterable {
    case browserControl
    case keychain
    case workspaceStorage
}

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
        case .needsAction: "Needs attention"
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

    var issue: MacOSPermissionIssue? {
        if case .needsAction(let issue) = self { return issue }
        return nil
    }
}

struct MacOSPermissionCheckItem: Equatable, Identifiable {
    let id: MacOSPermissionCheckID
    let title: String
    let subtitle: String
    var state: MacOSPermissionCheckState

    var readyMessage: String {
        switch id {
        case .browserControl: "ASTRA can use the controlled browser."
        case .keychain: "Credentials can be stored securely."
        case .workspaceStorage: "Workspace files can be created here."
        }
    }
}

@MainActor
final class MacOSPermissionsViewModel: ObservableObject {
    @Published private(set) var checks: [MacOSPermissionCheckItem]
    @Published private(set) var hasRunCheck = false

    private let browser = ControlledBrowserController()
    private let appDisplayName: String

    init(appDisplayName: String = AppBuildInfo.current.displayName) {
        self.appDisplayName = appDisplayName
        self.checks = MacOSPermissionsViewModel.initialChecks()
    }

    var isChecking: Bool {
        checks.contains { $0.state == .checking }
    }

    var readyCount: Int {
        checks.filter { $0.state == .ready }.count
    }

    var summaryText: String {
        if isChecking { return "Checking access" }
        if readyCount == checks.count { return "All ready" }
        if checks.contains(where: { $0.state.needsAttention }) { return "Needs attention" }
        return hasRunCheck ? "Needs attention" : "Preparing"
    }

    var isReady: Bool {
        readyCount == checks.count
    }

    var onboardingSummary: String {
        if isChecking { return "Checking..." }
        if isReady { return "Ready - browser, Keychain, and workspace files" }
        if !hasRunCheck { return "Not checked yet" }

        let attention = checks
            .filter { $0.state.needsAttention }
            .map(\.title)
        if attention.isEmpty {
            return "Needs attention"
        }
        return "Needs attention - \(attention.joined(separator: ", "))"
    }

    func checkAll(workspaceRoot: String) async {
        hasRunCheck = true
        checks = checks.map { item in
            var copy = item
            copy.state = .checking
            return copy
        }

        let keychainIssue = MacOSPermissionDiagnostics.checkKeychainAccess(appDisplayName: appDisplayName)
        setState(keychainIssue.map(MacOSPermissionCheckState.needsAction) ?? .ready, for: .keychain)

        let workspaceIssue = MacOSPermissionDiagnostics.checkWorkspaceRootAccess(
            appDisplayName: appDisplayName,
            workspaceRoot: workspaceRoot
        )
        setState(workspaceIssue.map(MacOSPermissionCheckState.needsAction) ?? .ready, for: .workspaceStorage)

        await browser.launch(initialAddress: "about:blank")
        if browser.isRunning {
            setState(.ready, for: .browserControl)
            return
        }

        if let browserIssue = MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: appDisplayName,
            browserName: browser.browserName,
            isRunning: browser.isRunning,
            runState: browser.runState,
            lastErrorMessage: browser.lastErrorMessage
        ) {
            setState(.needsAction(browserIssue), for: .browserControl)
        } else {
            setState(.unavailable(browser.lastErrorMessage ?? browser.statusMessage), for: .browserControl)
        }
    }

    func openSettings(for issue: MacOSPermissionIssue) {
        MacOSPermissionDiagnostics.openSettings(for: issue.kind)
    }

    private func setState(_ state: MacOSPermissionCheckState, for id: MacOSPermissionCheckID) {
        checks = checks.map { item in
            guard item.id == id else { return item }
            var copy = item
            copy.state = state
            return copy
        }
    }

    private static func initialChecks() -> [MacOSPermissionCheckItem] {
        [
            MacOSPermissionCheckItem(
                id: .browserControl,
                title: "Browser control",
                subtitle: "Use the separate controlled browser for web tasks.",
                state: .notChecked
            ),
            MacOSPermissionCheckItem(
                id: .keychain,
                title: "Keychain storage",
                subtitle: "Store capability tokens and connector secrets.",
                state: .notChecked
            ),
            MacOSPermissionCheckItem(
                id: .workspaceStorage,
                title: "Workspace files",
                subtitle: "Create task history, logs, and workspace config.",
                state: .notChecked
            )
        ]
    }
}

struct MacOSPermissionsSectionView: View {
    enum Context {
        case onboarding
        case settings
    }

    @ObservedObject private var model: MacOSPermissionsViewModel
    @State private var checkedWorkspaceRoot: String?
    private let context: Context
    private let workspaceRoot: String

    init(
        context: Context,
        workspaceRoot: String,
        model: MacOSPermissionsViewModel
    ) {
        self.context = context
        self.workspaceRoot = workspaceRoot
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                ForEach(model.checks) { check in
                    permissionRow(check)
                }
            }

            capabilityNote
        }
        .padding(16)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(summaryColor.opacity(0.22), lineWidth: 1)
        )
        .task(id: workspaceRoot) {
            guard checkedWorkspaceRoot != workspaceRoot else { return }
            checkedWorkspaceRoot = workspaceRoot
            await model.checkAll(workspaceRoot: workspaceRoot)
        }
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
                Text("Check browser control, secure credentials, and workspace storage.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(model.summaryText)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(summaryColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(summaryColor.opacity(0.10))
                .clipShape(Capsule())

            if model.hasRunCheck {
                Button {
                    Task { await model.checkAll(workspaceRoot: workspaceRoot) }
                } label: {
                    Label(model.isChecking ? "Checking" : "Retry", systemImage: "arrow.clockwise")
                        .font(Stanford.caption(12).weight(.semibold))
                }
                .disabled(model.isChecking)
            }
        }
    }

    private func permissionRow(_ check: MacOSPermissionCheckItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                statusIcon(for: check.state)

                VStack(alignment: .leading, spacing: 3) {
                    Text(check.title)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text(check.subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                statusPill(for: check.state)

                if let issue = check.state.issue {
                    Button {
                        model.openSettings(for: issue)
                    } label: {
                        Label(issue.actionTitle, systemImage: issue.systemImage)
                            .font(Stanford.caption(12).weight(.semibold))
                    }
                }
            }

            switch check.state {
            case .ready:
                rowMessage(check.readyMessage, tint: check.state.tint, icon: "checkmark.circle.fill")
            case .needsAction(let issue):
                rowMessage(issue.message, tint: check.state.tint, icon: "exclamationmark.triangle.fill")
                setupSteps(issue.setupSteps, tint: check.state.tint)
            case .unavailable(let detail):
                rowMessage(detail, tint: check.state.tint, icon: "xmark.octagon.fill")
                setupSteps(fallbackSteps(for: check.id), tint: check.state.tint)
            case .checking:
                rowMessage("Checking this access path...", tint: check.state.tint, icon: "arrow.triangle.2.circlepath")
            case .notChecked:
                rowMessage("Starting automatically...", tint: check.state.tint, icon: "clock")
            }
        }
        .padding(12)
        .background(check.state.tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusIcon(for state: MacOSPermissionCheckState) -> some View {
        if state == .checking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: state.symbolName)
                .font(Stanford.ui(17, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 22, height: 22)
        }
    }

    private func statusPill(for state: MacOSPermissionCheckState) -> some View {
        Text(state.statusText)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.10))
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private func rowMessage(_ message: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 2)
            Text(message)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func setupSteps(_ steps: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Setup steps")
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1)")
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(tint)
                        .clipShape(Circle())
                    Text(step)
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.black)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 30)
    }

    private var capabilityNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(Stanford.sky)
                .frame(width: 14)
                .padding(.top, 2)
            Text("Extra access, such as Apple Mail Automation, is checked when you enable that capability.")
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var summaryColor: Color {
        if model.isChecking { return Stanford.coolGrey }
        if model.readyCount == model.checks.count { return Stanford.statusHealthy }
        if model.checks.contains(where: { $0.state.needsAttention }) { return Stanford.statusWarn }
        return Stanford.coolGrey
    }

    private func fallbackSteps(for id: MacOSPermissionCheckID) -> [String] {
        switch id {
        case .browserControl:
            return [
                "Install Google Chrome, Microsoft Edge, Brave, or Chromium.",
                "Return to ASTRA and click Retry."
            ]
        case .keychain:
            return [
                "Open Keychain Access and unlock the login keychain.",
                "Return to ASTRA and click Retry."
            ]
        case .workspaceStorage:
            return [
                "Choose a workspace folder you can write to.",
                "Return to ASTRA and click Retry."
            ]
        }
    }
}

private extension MacOSPermissionCheckState {
    var needsAttention: Bool {
        switch self {
        case .needsAction, .unavailable: true
        case .notChecked, .checking, .ready: false
        }
    }
}
