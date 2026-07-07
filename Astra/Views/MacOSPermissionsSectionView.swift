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
    case deferred(String)
    case needsAction(MacOSPermissionIssue)
    case unavailable(String)

    var statusText: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking"
        case .ready: "Ready"
        case .deferred: "When needed"
        case .needsAction: "Needs attention"
        case .unavailable: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .notChecked: "circle.dotted"
        case .checking: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .deferred: "clock"
        case .needsAction: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notChecked, .checking, .deferred: Stanford.coolGrey
        case .ready: Stanford.statusHealthy
        case .needsAction: Stanford.statusWarn
        case .unavailable: Stanford.statusError
        }
    }

    var issue: MacOSPermissionIssue? {
        if case .needsAction(let issue) = self { return issue }
        return nil
    }

    var isReadyOrDeferred: Bool {
        switch self {
        case .ready, .deferred:
            return true
        case .notChecked, .checking, .needsAction, .unavailable:
            return false
        }
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
        if hasRunCheck, checks.allSatisfy(\.state.isReadyOrDeferred) { return "Ready for setup" }
        return hasRunCheck ? "Needs attention" : "Preparing"
    }

    var isReady: Bool {
        checks.allSatisfy(\.state.isReadyOrDeferred)
    }

    var onboardingSummary: String {
        if isChecking { return "Checking..." }
        if isReady { return "Ready - Keychain and workspace files" }
        if !hasRunCheck { return "Not checked yet" }

        let attention = checks
            .filter { $0.state.needsAttention }
            .map(\.title)
        if attention.isEmpty {
            return "Needs attention"
        }
        return "Needs attention - \(attention.joined(separator: ", "))"
    }

    func checkAll(workspaceRoot: String, includeBrowserControl: Bool = true) async {
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

        guard includeBrowserControl else {
            setState(
                .deferred("ASTRA will check controlled browser access the first time you open or use it."),
                for: .browserControl
            )
            return
        }

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

    private var shouldProbeBrowserControl: Bool {
        context == .settings
    }

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
            await model.checkAll(workspaceRoot: workspaceRoot, includeBrowserControl: shouldProbeBrowserControl)
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
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(Stanford.black)
                Text(headerSubtitle)
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
                    Task {
                        await model.checkAll(
                            workspaceRoot: workspaceRoot,
                            includeBrowserControl: shouldProbeBrowserControl
                        )
                    }
                } label: {
                    Label(model.isChecking ? "Checking" : "Retry", systemImage: "arrow.clockwise")
                        .font(Stanford.caption(12).weight(.semibold))
                }
                .disabled(model.isChecking)
            }
        }
    }

    private var headerSubtitle: String {
        switch context {
        case .onboarding:
            return "Check secure credentials and workspace storage. Browser control is checked when you use it."
        case .settings:
            return "Check browser control, secure credentials, and workspace storage."
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

                if let issue = check.state.issue {
                    Button {
                        if issue.kind == .keychain {
                            Task {
                                await model.checkAll(
                                    workspaceRoot: workspaceRoot,
                                    includeBrowserControl: shouldProbeBrowserControl
                                )
                            }
                        } else {
                            model.openSettings(for: issue)
                        }
                    } label: {
                        Label(issue.actionTitle, systemImage: issue.systemImage)
                            .font(Stanford.caption(12).weight(.semibold))
                    }
                }
            }

            switch check.state {
            case .ready:
                rowMessage(check.readyMessage)
            case .deferred(let message):
                rowMessage(message)
            case .needsAction(let issue):
                rowMessage(issue.message)
                setupSteps(issue.setupSteps, tint: check.state.tint)
            case .unavailable(let detail):
                rowMessage(detail)
                setupSteps(fallbackSteps(for: check.id), tint: check.state.tint)
            case .checking:
                rowMessage("Checking this access path...")
            case .notChecked:
                rowMessage("Starting automatically...")
            }
        }
        .padding(12)
        .background(rowBackground(for: check.state))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func rowBackground(for state: MacOSPermissionCheckState) -> some View {
        // P1/COL: keep the panel neutral inside the single card boundary.
        // Tint only exceptional rows that need extra emphasis.
        if state.needsAttention {
            state.tint.opacity(0.07)
        } else {
            Color.clear
        }
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

    private func rowMessage(_ message: String) -> some View {
        // ICO: the leading status icon already conveys the glyph; the message
        // line is plain text aligned under the title column.
        Text(message)
            .font(Stanford.caption(11))
            .foregroundStyle(Stanford.black)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 34)
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
            Text(accessNoteText)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var accessNoteText: String {
        switch context {
        case .onboarding:
            return "Browser control and capability-specific access are checked later, when you choose to use them."
        case .settings:
            return "Extra access, such as Apple Mail Automation, is checked when you enable that capability."
        }
    }

    private var summaryColor: Color {
        if model.isChecking { return Stanford.coolGrey }
        if model.readyCount == model.checks.count || model.checks.allSatisfy(\.state.isReadyOrDeferred) {
            return Stanford.statusHealthy
        }
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
                "Retry the Keychain-backed action from ASTRA.",
                "If macOS asks whether ASTRA can access its Keychain item, choose Allow or Always Allow.",
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
        case .notChecked, .checking, .ready, .deferred: false
        }
    }
}
