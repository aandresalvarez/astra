import Foundation
import ASTRACore
import ASTRAModels

/// Recognises a plugin CLI whose sign-in expired while the agent was using it,
/// from the output of the command the agent ran.
///
/// Before this, `gcloud` printing "Reauthentication required" was just a tool
/// error: the agent retried, gave up, or blamed the provider, and the person
/// had no button to fix it. Now the run stops with
/// `TaskRunStopReason.capabilitySessionExpired` and the task view offers the
/// sign-in and then Resume.
///
/// It fires only when the command that produced the output starts one of the
/// known CLIs and that command failed (the process monitor checks the tool
/// result's error flag), so an agent reading documentation or an issue body
/// that quotes these errors does not stop the run. Patterns are whole
/// diagnostics, not fragments.
enum CLISessionExpiryClassifier {
    struct Family: Equatable, Sendable {
        let commands: [String]
        let displayName: String
        let signInCommand: String
        let checkBinary: String
        let checkArguments: [String]
        let patterns: [String]

        var stopMessage: String {
            "The \(displayName) sign-in expired while the agent was using it. Run `\(signInCommand)`, then resume."
        }

        var repair: RepairAction {
            RepairAction(
                strategy: .terminal,
                componentName: "\(displayName) login",
                title: "Sign in to \(displayName)",
                verb: "Sign in",
                detail: "Run `\(signInCommand)` in Terminal, then resume the task.",
                command: signInCommand,
                checkBinary: checkBinary,
                checkArguments: checkArguments,
                checkExpect: checkBinary == "gcloud" ? SemanticCheck.stdoutNonEmpty.rawValue : nil
            )
        }
    }

    static let googleCloud = Family(
        commands: ["gcloud", "bq", "gsutil"],
        displayName: "Google Cloud",
        signInCommand: "gcloud auth login",
        checkBinary: "gcloud",
        checkArguments: ["config", "config-helper", "--format=value(credential.token_expiry)"],
        patterns: [
            "reauthentication required",
            "reauthentication failed",
            "invalid_grant",
            "problem refreshing your current auth tokens",
            "you do not currently have an active account selected",
            "does not have any valid credentials",
            "please run:\n\n  $ gcloud auth login"
        ]
    )

    static let gitHub = Family(
        commands: ["gh"],
        displayName: "GitHub",
        signInCommand: "gh auth login",
        checkBinary: "gh",
        checkArguments: ["auth", "status", "--hostname", "github.com"],
        patterns: [
            "you are not logged into any github hosts",
            "http 401: bad credentials",
            "the token in default is invalid",
            "the token in gh_token is invalid",
            "the token in github_token is invalid",
            "run gh auth login",
            "to get started with github cli, please run:  gh auth login"
        ]
    )

    static let families = [googleCloud, gitHub]

    struct Stop: Equatable {
        let reason: String
        let message: String
    }

    /// A stop when `content` is a sign-in failure printed by a command that
    /// runs one of the known CLIs.
    static func stop(content: String, command: String?) -> Stop? {
        guard let family = family(content: content, command: command) else { return nil }
        return Stop(reason: TaskRunStopReason.capabilitySessionExpired.rawValue, message: family.stopMessage)
    }

    static func family(content: String, command: String?) -> Family? {
        guard let command, !command.isEmpty else { return nil }
        let lowered = content.lowercased()
        return families.first { family in
            family.commands.contains { runs($0, in: command) }
                && family.patterns.contains { lowered.contains($0) }
        }
    }

    /// The family whose stop message this is; the message is ASTRA's own.
    static func family(forStopMessage message: String?) -> Family? {
        guard let message else { return nil }
        return families.first { $0.stopMessage == message }
    }

    /// True when `command` invokes `cli`, at the start or after a separator
    /// (`cd x && gcloud …`, `env A=b gcloud …`).
    static func runs(_ cli: String, in command: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: cli)
        return command.range(of: #"(^|[\s;&|(`$])"# + escaped + #"(\s|$)"#, options: .regularExpression) != nil
    }
}
