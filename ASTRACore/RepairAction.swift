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
    /// Variables the stopped run gave the CLI (a projected `GH_TOKEN` or
    /// `CLOUDSDK_CONFIG`), so the check sees what the resumed run will. Set
    /// when checking, not stored with the repair.
    public var checkEnvironment: [String: String]?
    /// The directory the resumed run starts in, where a relative or empty
    /// entry of the projected `PATH` (`./tools`) points. Set with
    /// `checkEnvironment`, not stored with the repair.
    public var checkWorkingDirectory: String?

    /// Credential-store selectors the failed command set on itself
    /// (`CLOUDSDK_CONFIG=/team gcloud …`), only `credentialStoreSelectors`:
    /// paths, no secret, so stored with the repair. `checking(in:)` lays
    /// them over the resumed run's variables.
    public var checkSelectors: [String: String]?

    /// `checkEnvironment` can hold a token: it is never encoded, nor is
    /// `checkWorkingDirectory`, which belongs with it.
    private enum CodingKeys: String, CodingKey {
        case strategy, componentName, title, verb, detail, command, url, checkBinary, checkArguments, checkExpect, checkSelectors
    }

    /// This repair checking with `environment` (the resumed run's
    /// variables) and, over it, the store the failed command selected.
    public func checking(in environment: [String: String]?) -> RepairAction {
        var checked = self
        let selectors = (checkSelectors ?? [:]).filter { Self.credentialStoreSelectors.contains($0.key) }
        let merged = (environment ?? [:]).merging(selectors) { _, own in own }
        checked.checkEnvironment = merged.isEmpty ? nil : merged
        return checked
    }

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
    /// as a declared local tool (`LocalToolSecurityPolicy`). And it may only
    /// sign in (`TerminalRepairPolicy`): `gcloud projects delete victim
    /// --quiet` is a plain call to the CLI too, and one click would run it.
    /// Selector-prefixed historical commands also fail this final check:
    /// a task-selected directory cannot become a credential destination.
    public static func isSafeTerminalCommand(
        _ command: String, binary: String?, allowsInstaller: Bool
    ) -> Bool {
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
        // The executable is the declared CLI itself, written exactly as the
        // check declares it: a bare name (found on PATH, like the check) or
        // that exact path. A same-named file elsewhere (`./gcloud`,
        // `/tmp/gcloud`) is a different program, and so is a bare name when
        // the check runs a path: Terminal would resolve it through PATH.
        let arguments = Array(words.dropFirst())
        // A path must be an installed copy of the CLI (`TrustedExecutablePath`):
        // `/tmp/plugin/gh` named after the GitHub CLI is not it.
        if let binary, executable == binary {
            guard !binary.contains("/") || TrustedExecutablePath.isInstalled(binary) else { return false }
            return TerminalRepairPolicy.isSignIn(cli: (binary as NSString).lastPathComponent, arguments: arguments)
        }
        guard allowsInstaller, installers.contains(executable), let binary, TrustedExecutablePath.isTrustedDeclaration(binary) else { return false }
        return TerminalRepairPolicy.isInstall(cli: (binary as NSString).lastPathComponent, arguments: arguments)
    }

    /// Non-secret selectors retained for the stopped run's read-only check.
    /// They never authorize writing a login into a task-selected directory.
    public static let credentialStoreSelectors = ["CLOUDSDK_CONFIG", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "GH_HOST"]

    /// Task-selected directories are not trusted credential destinations.
    /// Preserve their read-only verification context, but never put them in
    /// a Terminal command that writes a fresh login. A non-default GitHub
    /// host needs manual setup too; github.com needs no selector forwarding.
    public func targetingCredentialStore(_ environment: [String: String]?) -> RepairAction {
        guard strategy == .terminal, command != nil else { return self }
        if verb == "Install", let executable = command?.split(whereSeparator: \.isWhitespace).first,
           Self.installers.contains(String(executable)) { return enforcingTerminalPolicy() }
        let cli = ((checkBinary ?? "") as NSString).lastPathComponent
        let directories: [String]
        switch cli {
        case "gcloud": directories = ["CLOUDSDK_CONFIG"]
        case "gh": directories = ["GH_CONFIG_DIR", "XDG_CONFIG_HOME"]
        default: directories = ["XDG_CONFIG_HOME"]
        }
        let selected = checking(in: environment).checkEnvironment
        let hasDirectory = directories.contains { selected?[$0]?.isEmpty == false }
        let host = cli == "gh" ? (selected?["GH_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
        if hasDirectory || (!host.isEmpty && host.lowercased() != "github.com") {
            return requiringManualCredentialSetup()
        }
        return enforcingTerminalPolicy()
    }

    /// Applied to newly generated and decoded repairs alike. A rejected
    /// command becomes an actionable check, not a Sign in button that does
    /// nothing or copies an unsafe command to the clipboard.
    public func enforcingTerminalPolicy() -> RepairAction {
        guard strategy == .terminal, let command else { return self }
        guard Self.isSafeTerminalCommand(command, binary: checkBinary, allowsInstaller: verb == "Install")
        else { return requiringManualCredentialSetup() }
        if isGitHubSignIn(command), let arguments = checkArguments {
            for (index, argument) in arguments.enumerated() {
                let host: String?
                if argument == "--hostname" || argument == "-h" {
                    host = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
                } else if argument.hasPrefix("--hostname=") {
                    host = String(argument.dropFirst("--hostname=".count))
                } else { host = nil }
                if let host, host.lowercased() != "github.com" { return requiringManualCredentialSetup() }
            }
        }
        return self
    }

    /// The final command is admitted against stored and current selectors.
    /// Pin GitHub's default explicitly so Terminal's ambient GH_HOST cannot
    /// silently change the login destination.
    public var executionCommand: String? {
        let admitted = targetingCredentialStore(checkEnvironment)
        guard admitted.strategy == .terminal, let command = admitted.command else { return nil }
        let words = command.split(whereSeparator: \.isWhitespace)
        if admitted.isGitHubSignIn(command), !words.contains(where: {
            $0 == "--hostname" || $0 == "-h" || $0.hasPrefix("--hostname=")
        }) { return command + " --hostname github.com" }
        return command
    }

    private func isGitHubSignIn(_ command: String) -> Bool {
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return executable == checkBinary && ((checkBinary ?? "") as NSString).lastPathComponent == "gh"
    }

    private func requiringManualCredentialSetup() -> RepairAction {
        var manual = self
        manual.command = nil
        manual.verb = "Check"
        manual.title = "Set up \(componentName)"
        manual.detail = "Sign in manually using a trusted account and credential location, then check again."
        return manual
    }

    private static func guidance(_ hint: String) -> String {
        let plain = hint.unicodeScalars.prefix(2_048).map { scalar -> String in
            if scalar.properties.generalCategory == .format { return "" }
            return CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        return String(plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(600))
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
                // Prose-only guidance ("Start Docker Desktop…") has nothing
                // to run: the person follows it and ASTRA checks again. It is
                // not a reason to offer Install for a CLI that is installed.
                if step.command == nil, verb != "Install", let binary = check?.binary {
                    return RepairAction(
                        strategy: .terminal, componentName: component.name, title: component.name, verb: "Check",
                        detail: step.hint.map(Self.guidance) ?? "Fix \(component.name), then ASTRA checks again.",
                        checkBinary: binary, checkArguments: check?.arguments, checkExpect: check?.expect
                    )
                }
                guard let command = step.command else { continue }
                guard isSafeTerminalCommand(command, binary: check?.binary, allowsInstaller: verb == "Install") else {
                    // Not a known CLI's listed sign-in, nor its reviewed
                    // install (`TerminalRepairPolicy`): no button runs it.
                    // The plugin's own words still say what to do, and ASTRA
                    // checks again.
                    guard let hint = step.hint, let binary = check?.binary else { continue }
                    return RepairAction(
                        strategy: .terminal, componentName: component.name, title: component.name, verb: "Check",
                        detail: Self.guidance(hint), checkBinary: binary, checkArguments: check?.arguments, checkExpect: check?.expect
                    )
                }
                return RepairAction(
                    strategy: .terminal, componentName: component.name,
                    title: component.name, verb: verb == "Install" ? verb : "Sign in",
                    detail: "Run `\(command)`, then ASTRA checks again.",
                    command: command, checkBinary: check?.binary, checkArguments: check?.arguments,
                    checkExpect: check?.expect
                ).enforcingTerminalPolicy()
            case .url:
                // Only a web page: a package's install link must not open a
                // file, a share or another app's scheme.
                guard let url = step.url, isSafeRepairURL(url) else { continue }
                return RepairAction(
                    strategy: .url, componentName: component.name, title: component.name, verb: verb,
                    detail: step.hint.map(Self.guidance) ?? "Open the page, then come back to ASTRA.",
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
