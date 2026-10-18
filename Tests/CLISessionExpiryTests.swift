import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A plugin CLI's sign-in expiring mid-task stops the run with a repair the
/// task view can offer, then Resume (Plugins 2.0 phase 2 exit criterion).
@Suite("CLI session expiry")
struct CLISessionExpiryTests {
    private let gcloudReauth = """
    ERROR: (gcloud.projects.list) There was a problem refreshing your current auth tokens: \
    Reauthentication failed. cannot prompt during non-interactive execution.
    Please run:

      $ gcloud auth login

    to obtain new credentials.
    """

    @Test("gcloud, bq and gsutil reauth output is a session expiry")
    func googleCloudExpiryIsRecognised() {
        for command in ["gcloud projects list", "cd /tmp && bq query 'select 1'", "env X=1 gsutil ls gs://b"] {
            let stop = CLISessionExpiryClassifier.stop(content: gcloudReauth, command: command)
            #expect(stop?.reason == "capability_session_expired", "missed: \(command)")
            #expect(stop?.message.contains("gcloud auth login") == true)
        }
    }

    @Test("The same text from a command that is not the CLI does not stop the run")
    func quotedErrorsDoNotStopTheRun() {
        #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: "cat docs/gcloud-errors.md") == nil)
        #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: nil) == nil)
        #expect(CLISessionExpiryClassifier.stop(content: "Listed 0 items.", command: "gcloud projects list") == nil)
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "ghost --help"))
    }

    @Test("Only an executed CLI counts: by basename, after wrappers, never as an argument")
    func onlyExecutedCLIsCount() {
        #expect(CLISessionExpiryClassifier.runs("gcloud", in: "/opt/homebrew/bin/gcloud projects list"))
        #expect(CLISessionExpiryClassifier.runs("gcloud", in: "A=1 B=2 env gcloud auth list"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cd repo && gh pr list | head"))
        #expect(CLISessionExpiryClassifier.runs("gsutil", in: "echo $(gsutil ls)"))
        #expect(!CLISessionExpiryClassifier.runs("gcloud", in: "grep gcloud notes.txt"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo gh is the GitHub CLI"))
        #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: "grep gcloud notes.txt") == nil)
        // A wrapper's options (and the values they take) come before the CLI.
        #expect(CLISessionExpiryClassifier.runs("gcloud", in: "env -i gcloud projects list"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "sudo -u build gh pr list"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "sudo -E -- gh pr list"))
        #expect(CLISessionExpiryClassifier.runs("gcloud", in: "env -u HOME X=1 gcloud auth list"))
        #expect(!CLISessionExpiryClassifier.runs("gcloud", in: "env --help"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "sudo -u gh whoami"))
        // Quoting is honored: a quoted space or separator is inside a word.
        #expect(CLISessionExpiryClassifier.runs("gh", in: "env NOTE='x y' gh pr list"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo '; gh pr list'"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo \"a | gh\""))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cd 'my repo' && \"gh\" pr list"))
    }

    @Test("env -S splits its operand into the command it runs")
    func envSplitStringRunsItsOperand() {
        for command in [
            "env -S 'gh auth token'", "env -S'gh auth token'", "env --split-string='gh auth token'",
            "env --split-string 'gh auth token'", "env -i -S 'X=1 /usr/local/bin/gh api user'", "env -S 'gh' auth token"
        ] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "missed: \(command)")
        }
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "env -S 'echo gh'"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "env -S"))
        let stop = CLISessionExpiryClassifier.stop(
            content: "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            command: "env -S 'gh auth token'"
        )
        #expect(stop?.reason == TaskRunStopReason.capabilitySessionExpired.rawValue)
    }

    @Test("A substitution inside double quotes still runs; inside single quotes it is text")
    func doubleQuotedSubstitutionsRun() {
        #expect(CLISessionExpiryClassifier.runs("gh", in: "token=\"$(gh auth token)\""))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "x=\"`gh auth token`\""))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "echo \"user: $(gh api user --jq \".login\") ok\""))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "echo \"$(echo $(gh auth token))\""))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "token=$(gh auth token)"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "x=`gh auth token`"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo '$(gh auth token)'"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo '`gh auth token`'"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo \"\\$(gh auth token)\""))
        // Text after the substitution is back inside the quote.
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "echo \"$(date) ; gh pr list\""))
        #expect(CLISessionExpiryClassifier.simpleCommands("token=\"$(gh auth token)\"") == [["token=$"], ["gh", "auth", "token"]])
    }

    @Test("A bad GH_TOKEN stops with advice about the variable, not a sign-in")
    func environmentTokenIsNotASignIn() throws {
        let output = "The token in GH_TOKEN is invalid.\nTo get started with GitHub CLI, please run:  gh auth login"
        let family = try #require(CLISessionExpiryClassifier.family(content: output, command: "gh pr list"))
        #expect(family == CLISessionExpiryClassifier.gitHubEnvironmentToken)
        #expect(!family.offersSignIn)
        #expect(family.stopMessage.contains("GH_TOKEN"))
        #expect(CLISessionExpiryClassifier.family(forStopMessage: family.stopMessage) == family)
        // Its repair only checks; a failed check repeats the token advice.
        #expect(family.repair.command == nil)
        #expect(family.repair.checkBinary == "gh")
        #expect(family.repair.detail.contains("GH_TOKEN"))
        #expect(!family.repair.detail.contains("gh auth login"))
        // A token the check is given never goes into a stored repair.
        var checked = family.repair
        checked.checkEnvironment = ["GH_TOKEN": "secret-token"]
        #expect(!checked.encoded().contains("secret-token"))
        #expect(RepairAction.decode(from: checked.encoded())?.checkEnvironment == nil)
    }

    @Test("gh logged out is a GitHub session expiry")
    func gitHubExpiryIsRecognised() {
        let stop = CLISessionExpiryClassifier.stop(
            content: "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            command: "gh pr list"
        )
        #expect(stop?.message.contains("`gh auth login`") == true)
        #expect(CLISessionExpiryClassifier.family(forStopMessage: stop?.message) == CLISessionExpiryClassifier.gitHub)
    }

    @Test("A GitHub Enterprise failure signs in to and checks the host that failed")
    func gitHubEnterpriseHostIsCarried() throws {
        let output = "HTTP 401: Bad credentials (https://github.example.com/api/v3/user)"
        for command in [
            "GH_HOST=github.example.com gh api user", "env GH_HOST=GitHub.Example.com gh api user",
            "gh api user --hostname github.example.com", "gh auth token --hostname=github.example.com"
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "missed: \(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--hostname", "github.example.com"], "\(command)")
            #expect(family.repair.command == "gh auth login --hostname github.example.com")
            #expect(RepairAction.isSafeTerminalCommand(try #require(family.repair.command), binary: "gh", allowsInstaller: false))
        }
        // github.com, or a value that is not a host name, keeps the default check.
        for command in ["GH_HOST=github.com gh api user", "gh api user --hostname 'x;rm -rf /'"] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub)
        }
        // A host the launch environment picks retargets the default check.
        var projected = CLISessionExpiryClassifier.gitHub.repair
        projected.checkEnvironment = ["GH_HOST": "github.example.com", "GH_ENTERPRISE_TOKEN": "enterprise-token"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).checkArguments?.last == "github.example.com")
    }

    @Test("A rejected Enterprise token stops with token guidance and keeps the host it targeted")
    func gitHubEnterpriseTokenIsRecognised() throws {
        for variable in ["GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
            let output = "The token in \(variable) is invalid.\nTo re-authenticate, run: gh auth login"
            let stop = try #require(CLISessionExpiryClassifier.stop(
                content: output, command: "GH_HOST=github.example.com gh auth status"
            ), "missed: \(variable)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message))
            #expect(family.offersSignIn == false)
            #expect(family.repair.command == nil)
            #expect(family.repair.detail.contains("GH_ENTERPRISE_TOKEN"))
            #expect(family.repair.checkArguments == ["auth", "status", "--hostname", "github.example.com"], "\(variable)")
        }
        // Without a targeted host the stop still round-trips to the token family.
        let plain = try #require(CLISessionExpiryClassifier.family(
            content: "The token in GH_ENTERPRISE_TOKEN is invalid.", command: "gh api user"
        ))
        #expect(plain == CLISessionExpiryClassifier.gitHubEnterpriseToken)
        #expect(CLISessionExpiryClassifier.family(forStopMessage: plain.stopMessage) == plain)
    }

    @Test("The process monitor stops the run when the agent's gcloud call hits an expired sign-in")
    func monitorStopsOnExpiredSignIn() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        let commandKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "toolu_gcloud", input: ["command": "gcloud projects list --format=json"]),
            process: nil
        )
        let resultKill = monitor.processEvent(
            .toolResult(toolId: "toolu_gcloud", content: gcloudReauth, isError: true),
            process: nil
        )
        #expect(commandKill == false)
        #expect(resultKill == true)
        #expect(monitor.runtimeStopReason == "capability_session_expired")
        #expect(AgentRuntimeWorker.isTerminalRuntimeStop("capability_session_expired"))
        #expect(CLISessionExpiryClassifier.family(forStopMessage: monitor.runtimeStopMessage) == CLISessionExpiryClassifier.googleCloud)
    }

    @Test("A successful command whose output quotes a sign-in error does not stop the run")
    func successfulOutputQuotingTheErrorDoesNotStop() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(
            .toolUse(name: "Bash", id: "toolu_gh", input: ["command": "gh issue view 12"]),
            process: nil
        )
        let kill = monitor.processEvent(
            .toolResult(toolId: "toolu_gh", content: "Bug: after rotating, gh says: You are not logged into any GitHub hosts.", isError: false),
            process: nil
        )
        #expect(kill == false)
        #expect(monitor.runtimeStopReason == nil)
    }

    @Test("A pipeline that masks the CLI's failure still stops the run")
    func maskedPipelineFailureStopsTheRun() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(
            .toolUse(name: "Bash", id: "toolu_pipe", input: ["command": "gcloud projects list | cat"]),
            process: nil
        )
        // `cat` exits 0, so the shell reports success for the whole line.
        let kill = monitor.processEvent(
            .toolResult(toolId: "toolu_pipe", content: gcloudReauth, isError: false),
            process: nil
        )
        #expect(kill == true)
        #expect(monitor.runtimeStopReason == "capability_session_expired")
    }

    @Test("A successful line counts only when a later command decided its exit status")
    func successfulLinesNeedAMaskedCLI() {
        for command in [
            "gcloud projects list | cat", "gcloud projects list 2>&1 | head -5", "(gcloud projects list) | cat",
            "gcloud projects list || true", "gcloud projects list; echo done", "cd /tmp && bq ls |& tee out.txt"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: command, failed: false) != nil, "missed: \(command)")
        }
        for command in [
            "cat notes.md", "echo \"Reauthentication failed. Please run gcloud auth login\" | cat",
            "gcloud projects list", "cd /tmp && gcloud projects list", "gcloud projects list && echo ok",
            "gcloud projects list 2>&1", "gcloud projects list &>out.txt", "gcloud projects list;"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: command, failed: false) == nil, "stopped: \(command)")
        }
        // A redirection's `&` is not an operator that ends a command.
        #expect(CLISessionExpiryClassifier.simpleCommands("gcloud auth list 2>&1") == [["gcloud", "auth", "list", "2>&1"]])

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "Bash", id: "toolu_cat", input: ["command": "cat notes.md"]), process: nil)
        let kill = monitor.processEvent(.toolResult(toolId: "toolu_cat", content: gcloudReauth, isError: false), process: nil)
        #expect(kill == false)
        #expect(monitor.runtimeStopReason == nil)
    }

    @Test("A shell-negated CLI runs, and its failure is the line's success")
    func shellNegationMasksTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["! gh auth status", "cd /tmp && ! gh auth status", "time ! gh auth status", "( ! gh auth status )"] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "not run: \(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "missed: \(command)")
        }
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "! cat notes.md", failed: false) == nil)
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "echo ! gh auth status", failed: false) == nil)
    }

    @Test("A substitution inside another command masks the CLI's failure; an assignment does not")
    func substitutionInsideAnotherCommandMasksTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in [
            "echo \"$(gh auth token)\"", "echo $(gh auth token)", "printf '%s' \"`gh auth token`\"",
            "echo \"$(echo $(gh auth token))\""
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "missed: \(command)")
        }
        #expect(CLISessionExpiryClassifier.stop(content: gcloudReauth, command: "printf '%s' \"$(gcloud projects list)\"", failed: false) != nil)
        for command in [
            "token=$(gh auth token)", "token=\"$(gh auth token)\"", "(gh auth token)", "$(gh auth token)",
            "gh api \"$(gh auth token)\"", "cat notes.md", "echo '$(gh auth token)'"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) == nil, "stopped: \(command)")
        }
    }

    @Test("The run's repair event reaches the dock, scoped to that run")
    func stopEvidenceReadsTheRunsRepair() throws {
        let task = AgentTask(title: "Export", goal: "List projects")
        let earlier = TaskRun(task: task)
        let latest = TaskRun(task: task)
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        let events = [
            snapshot(task, earlier, TaskEventTypes.System.runtimeRepairRequired, repair.encoded()),
            snapshot(task, latest, TaskEventTypes.System.error, "stopped"),
            snapshot(task, latest, TaskEventTypes.System.runtimeRepairRequired, repair.encoded())
        ]
        #expect(TaskRunStopEvidence.repair(events: events, runID: latest.id) == repair)
        #expect(TaskRunStopEvidence.repair(events: Array(events.prefix(2)), runID: latest.id) == nil)
        #expect(repair.checkArguments == ["config", "config-helper", "--format=value(credential.token_expiry)"])
    }

    @Test("A sign-in runs in Terminal, and falls back to copying the command")
    @MainActor
    func repairRunnerLaunchesOrCopies() {
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        let launcher = RecordingTerminal()
        var copied: [String] = []
        RepairActionRunner.run(repair, terminal: launcher, copy: { copied.append($0) })
        #expect(launcher.launched == ["gcloud auth login"])
        #expect(copied.isEmpty)

        let refusing = RecordingTerminal(refuses: true)
        RepairActionRunner.run(repair, terminal: refusing, copy: { copied.append($0) })
        #expect(copied == ["gcloud auth login"])
        #expect(refusing.openedTerminal)
    }

    @Test("A stored repair page opens only when it is an https URL")
    @MainActor
    func repairRunnerRevalidatesStoredURLs() throws {
        var opened: [URL] = []
        for target in ["https://cloud.google.com/sdk/docs/install", "file:///etc/passwd", "smb://host/share", "astra-evil://x"] {
            let stored = RepairAction(
                strategy: .url, componentName: "Google Cloud CLI", title: "Install", verb: "Install",
                detail: "", url: URL(string: target)
            )
            let decoded = try #require(RepairAction.decode(from: stored.encoded()))
            RepairActionRunner.run(decoded, terminal: RecordingTerminal(), openURL: { opened.append($0) })
        }
        #expect(opened.map(\.absoluteString) == ["https://cloud.google.com/sdk/docs/install"])
    }

    private func snapshot(_ task: AgentTask, _ run: TaskRun, _ type: TaskEventType, _ payload: String) -> TaskEventSnapshot {
        TaskEventSnapshot(event: TaskEvent(task: task, eventType: type, payload: payload, run: run))
    }
}

private final class RecordingTerminal: TerminalCommandLaunching, @unchecked Sendable {
    let refuses: Bool
    var launched: [String] = []
    var openedTerminal = false

    init(refuses: Bool = false) { self.refuses = refuses }

    @MainActor
    func launchInTerminal(command: String) throws {
        if refuses { throw TerminalLaunchError(reason: "denied") }
        launched.append(command)
    }

    func openTerminalApp() { openedTerminal = true }
}
