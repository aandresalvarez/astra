import AppKit
import ASTRACore

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
                      command, binary: repair.checkBinary, allowsInstaller: repair.verb == "Install"
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
