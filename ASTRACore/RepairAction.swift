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
    /// --quiet` is a plain call to the CLI too, and one click would run it. With
    /// `allowsStoreSelectors`, ASTRA's own sign-in may lead with the
    /// credential-store selectors `targetingCredentialStore` adds; a
    /// plugin's declared command never does.
    public static func isSafeTerminalCommand(
        _ command: String, binary: String?, allowsInstaller: Bool, allowsStoreSelectors: Bool = false
    ) -> Bool {
        // Terminal runs the command exactly as written, so a newline (or any
        // other control character) would start a second command that the
        // word-by-word check below never sees. Only plain spaces separate words.
        guard !command.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        guard let command = allowsStoreSelectors ? droppingSelectorPrefix(command) : command else { return false }
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

    /// Variables that pick which credential store a CLI signs in to and
    /// reads, and hold no secret: a sign-in may carry them into Terminal.
    public static let credentialStoreSelectors = ["CLOUDSDK_CONFIG", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "GH_HOST"]

    /// This repair with its Terminal command run against the credential
    /// store `environment` selects (the stopped run's), as
    /// `env CLOUDSDK_CONFIG='/path' gcloud auth login`: signing in to the
    /// default store would leave the one the resumed run reads still broken.
    /// Only `credentialStoreSelectors` are carried, never a token. An
    /// apostrophe (`/Users/O'Connor/.config/gh`) is written `'\''`: closed,
    /// escaped, reopened. Unchanged without a command or a selector, or when
    /// a value holds a control character, which no quoting makes one word.
    public func targetingCredentialStore(_ environment: [String: String]?) -> RepairAction {
        let selectors = Self.credentialStoreSelectors.compactMap { name in
            environment?[name].flatMap { $0.isEmpty ? nil : (name, $0) }
        }
        guard let command, !selectors.isEmpty,
              selectors.allSatisfy({ !$0.1.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { return self }
        var targeted = self
        targeted.command = "env " + selectors.map {
            "\($0.0)='\($0.1.replacingOccurrences(of: "'", with: #"'\''"#))' "
        }.joined() + command
        return targeted
    }

    /// `command` without a leading `env NAME='value' …` that sets only
    /// `credentialStoreSelectors`, each single-quoted so the shell takes it
    /// literally, an apostrophe as `'\''` (`targetingCredentialStore`);
    /// `command` itself without one; nil when the prefix sets anything else
    /// or is malformed.
    static func droppingSelectorPrefix(_ command: String) -> String? {
        guard command.hasPrefix("env ") else { return command }
        var rest = command.dropFirst("env ".count)
        var selectors = 0
        while let assignment = rest.range(of: #"^[A-Z_]+='[^']*'(\\''[^']*')* "#, options: .regularExpression) {
            let name = rest[assignment].prefix { $0 != "=" }
            guard credentialStoreSelectors.contains(String(name)) else { return nil }
            rest = rest[assignment.upperBound...]
            selectors += 1
        }
        return selectors > 0 ? String(rest) : nil
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
                        detail: step.hint ?? "Fix \(component.name), then ASTRA checks again.",
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
                        detail: hint, checkBinary: binary, checkArguments: check?.arguments, checkExpect: check?.expect
                    )
                }
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
