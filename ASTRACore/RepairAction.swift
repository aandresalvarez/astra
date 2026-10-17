import Foundation

/// One thing a person does to get a plugin component working again, and how
/// ASTRA checks it worked (Plugins 2.0 health and repair).
///
/// Built from a component's setup contract for the rail, and from a stopped
/// run for the task view, so both render the same verb and run the same
/// strategy.
public struct RepairAction: Codable, Sendable, Equatable {
    public enum Strategy: String, Codable, Sendable, Equatable {
        /// Run `command` in Terminal, then re-check until the check passes.
        case terminal
        /// Open `url`, then re-check when ASTRA comes back to the front.
        case url
        /// Sign in with a device code inside ASTRA.
        case deviceCode
        /// Enter credentials in the connector editor.
        case credentialForm
    }

    public var strategy: Strategy
    /// The component this repairs, e.g. "Google Cloud login".
    public var componentName: String
    /// What the dock or row says, e.g. "Sign in to Google Cloud".
    public var title: String
    /// The button, e.g. "Sign in".
    public var verb: String
    /// One sentence on what happens next, e.g. "Run `gcloud auth login`, then resume."
    public var detail: String
    public var command: String?
    public var url: URL?
    /// How to re-check: the binary and arguments of the component's check.
    public var checkBinary: String?
    public var checkArguments: [String]?
    /// The check's semantic test (`SemanticCheck` raw value), if any.
    public var checkExpect: String?

    public init(
        strategy: Strategy,
        componentName: String,
        title: String,
        verb: String,
        detail: String,
        command: String? = nil,
        url: URL? = nil,
        checkBinary: String? = nil,
        checkArguments: [String]? = nil,
        checkExpect: String? = nil
    ) {
        self.strategy = strategy
        self.componentName = componentName
        self.title = title
        self.verb = verb
        self.detail = detail
        self.command = command
        self.url = url
        self.checkBinary = checkBinary
        self.checkArguments = checkArguments
        self.checkExpect = checkExpect
    }

    /// Package managers an install step may run besides the component's CLI.
    public static let installers: Set<String> = ["brew"]

    /// A Terminal repair comes from the plugin, so it must be a plain call to
    /// the component's own CLI (or, to install it, a package manager) with no
    /// shell syntax: `gcloud auth login` yes, `curl … | sh` no. The same rule
    /// as a declared local tool (`LocalToolSecurityPolicy`).
    public static func isSafeTerminalCommand(_ command: String, binary: String?, allowsInstaller: Bool) -> Bool {
        // Terminal runs the command exactly as written, so a newline (or any
        // other control character) would start a second command that the
        // word-by-word check below never sees. Only plain spaces separate words.
        guard !command.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = words.first else { return false }
        guard LocalToolSecurityPolicy.unsafeInvocationReason(
            command: executable,
            arguments: words.dropFirst().joined(separator: " ")
        ) == nil else { return false }
        let name = (executable as NSString).lastPathComponent
        if let binary, name == (binary as NSString).lastPathComponent { return true }
        return allowsInstaller && installers.contains(name)
    }

    /// The repair a component's setup contract offers: its `repair` step,
    /// else `connect`, else `install`; or `install` first when the component's
    /// binary is missing. Nil when none can be acted on.
    public static func from(_ component: PluginComponent, needsInstall: Bool = false) -> RepairAction? {
        let setup = component.setup
        let check = setup.check
        let order = needsInstall
            ? [(setup.install, "Install")]
            : [(setup.repair, "Fix"), (setup.connect, "Connect"), (setup.install, "Install")]
        for (step, verb) in order {
            guard let step else { continue }
            switch step.kind {
            case .terminal:
                guard let command = step.command,
                      isSafeTerminalCommand(command, binary: check?.binary, allowsInstaller: verb == "Install")
                else { continue }
                return RepairAction(
                    strategy: .terminal, componentName: component.name,
                    title: component.name, verb: verb == "Install" ? verb : "Sign in",
                    detail: "Run `\(command)`, then ASTRA checks again.",
                    command: command, checkBinary: check?.binary, checkArguments: check?.arguments,
                    checkExpect: check?.expect
                )
            case .url:
                // Only a web page: a package's install link must not open a
                // file, a share or another app's scheme.
                guard let url = step.url, isSafeRepairURL(url) else { continue }
                return RepairAction(
                    strategy: .url, componentName: component.name, title: component.name, verb: verb,
                    detail: step.hint ?? "Open the page, then come back to ASTRA.",
                    url: url, checkBinary: check?.binary, checkArguments: check?.arguments,
                    checkExpect: check?.expect
                )
            case .credentialForm:
                return RepairAction(
                    strategy: .credentialForm, componentName: component.name, title: component.name,
                    verb: "Add key", detail: "Enter the account's credentials."
                )
            case .deviceCode:
                return RepairAction(
                    strategy: .deviceCode, componentName: component.name, title: component.name,
                    verb: "Sign in", detail: step.hint ?? "Sign in with a code."
                )
            default:
                continue
            }
        }
        return nil
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(from payload: String) -> RepairAction? {
        try? JSONDecoder().decode(RepairAction.self, from: Data(payload.utf8))
    }
}

public extension RepairAction {
    /// An https URL with a host: the only kind a repair opens.
    static func isSafeRepairURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }
}
