import AppKit
import Foundation
import ASTRACore
import ASTRAModels

/// Structured evidence a stopped run left for the decision dock, scoped to that
/// run via `TaskEventSnapshot.runID` rather than the whole thread's history.
/// Kept out of `TaskMainView`, which is at its line budget.
enum TaskRunStopEvidence {
    static func launchBlock(events: [TaskEventSnapshot], runID: UUID?) -> TaskRunLaunchBlockPayload? {
        latestPayload(events: events, runID: runID, type: TaskEventTypes.System.runtimeLaunchBlocked)
            .flatMap(TaskRunLaunchBlockPayload.decode(from:))
    }

    /// The repair the run stopped for (a plugin sign-in expired mid-task).
    static func repair(events: [TaskEventSnapshot], runID: UUID?) -> RepairAction? {
        latestPayload(events: events, runID: runID, type: TaskEventTypes.System.runtimeRepairRequired)
            .flatMap(RepairAction.decode(from:))
    }

    /// The repair Sign in runs: the run's, its sign-in aimed at the
    /// credential store the resumed task reads (`CLOUDSDK_CONFIG`,
    /// `GH_CONFIG_DIR`…), the store Resume's check reads too. Resolved on
    /// the click, not in `body`: it walks the task's launch scope. A GitHub
    /// Enterprise host the launch selects (`GH_HOST`, else `GH_REPO`) is the
    /// one signed in to, the host Resume's check retargets to
    /// (`checkingLaunchHost`).
    @MainActor
    static func signInRepair(events: [TaskEventSnapshot], runID: UUID?, task: AgentTask) -> RepairAction? {
        guard var repair = repair(events: events, runID: runID) else { return nil }
        repair.checkEnvironment = TaskLifecycleCoordinator.projectedCheckEnvironment(for: task, binary: repair.checkBinary)
        return CLISessionExpiryClassifier.checkingLaunchHost(repair).targetingCredentialStore(repair.checkEnvironment)
    }

    private static func latestPayload(events: [TaskEventSnapshot], runID: UUID?, type: TaskEventType) -> String? {
        guard let runID else { return nil }
        return events.last { $0.runID == runID && $0.type == type.rawValue }?.payload
    }
}

/// Runs a `RepairAction` from the decision dock: a command goes to Terminal
/// (or is copied, with Terminal opened, when scripting is not allowed), a page
/// opens in the browser. Resume relaunches through the worker's pre-launch
/// checks, which re-test the component before the provider starts.
@MainActor
enum RepairActionRunner {
    static func run(
        _ repair: RepairAction?,
        terminal: TerminalCommandLaunching = TerminalAppLauncher(),
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) },
        copy: (String) -> Void = { command in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    ) {
        guard let repair else { return }
        switch repair.strategy {
        case .terminal:
            // Checked again here: a repair can also arrive from a stored event.
            guard let command = repair.command,
                  RepairAction.isSafeTerminalCommand(
                      command, binary: repair.checkBinary, allowsInstaller: repair.verb == "Install", allowsStoreSelectors: true
                  )
            else { return }
            do {
                try terminal.launchInTerminal(command: command)
            } catch {
                copy(command)
                terminal.openTerminalApp()
            }
        case .url:
            // Checked again for the same reason: a stored event's URL never
            // passed package validation.
            if let url = repair.url, RepairAction.isSafeRepairURL(url) { openURL(url) }
        case .deviceCode, .credentialForm:
            break
        }
    }
}
