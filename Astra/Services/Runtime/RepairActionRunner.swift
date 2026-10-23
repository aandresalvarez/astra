import AppKit
import ASTRACore

/// Runs a `RepairAction` from the decision dock: a command goes to Terminal
/// (or is copied, with Terminal opened, when scripting is not allowed), a page
/// opens in the browser. Resume relaunches through the worker's pre-launch
/// checks, which re-test the component before the provider starts.
@MainActor
enum RepairActionRunner {
    enum Outcome: Equatable { case launched, copied, refused }

    @discardableResult
    static func run(
        _ repair: RepairAction?,
        terminal: TerminalCommandLaunching = TerminalAppLauncher(),
        resolveExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) },
        isInstalled: (String) -> Bool = { TrustedExecutablePath.isInstalled($0) && FileManager.default.isExecutableFile(atPath: $0) },
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) },
        copy: (String) -> Void = { command in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    ) -> Outcome {
        guard let repair else { return .refused }
        switch repair.strategy {
        case .terminal:
            // Checked again here: a repair can also arrive from a stored event.
            guard let admitted = repair.executionCommand,
                  let executable = admitted.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return .refused }
            let resolved = executable.contains("/") ? executable : resolveExecutable(executable)
            // Terminal's interactive aliases, functions and PATH must not
            // replace the executable ASTRA admitted. Revalidate immediately
            // before launch, including symlink destinations and executability.
            guard TrustedExecutablePath.installedPath(resolved) != nil, isInstalled(resolved) else { return .refused }
            let command = ([resolved] + admitted.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)).joined(separator: " ")
            do {
                try terminal.launchInTerminal(command: command)
                return .launched
            } catch {
                copy(command)
                terminal.openTerminalApp()
                return .copied
            }
        case .url:
            // Checked again for the same reason: a stored event's URL never
            // passed package validation.
            if let url = repair.url, RepairAction.isSafeRepairURL(url) { openURL(url); return .launched }
            return .refused
        case .deviceCode, .credentialForm:
            return .refused
        }
    }
}
