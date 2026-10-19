import Foundation
import SwiftData
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

    @Test("An Enterprise host picked by -R/--repo or GH_REPO is the one signed in to and checked")
    func gitHubRepositorySelectorHostIsCarried() throws {
        let output = "HTTP 401: Bad credentials (https://github.example.com/api/v3/repos/team/app/pulls)"
        for command in [
            "gh pr list -R github.example.com/team/app", "gh pr list --repo GitHub.Example.com/team/app",
            "gh pr list --repo=github.example.com/team/app", "gh pr list -Rgithub.example.com/team/app",
            "GH_REPO=github.example.com/team/app gh pr list", "env GH_REPO=github.example.com/team/app gh pr list"
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "missed: \(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--hostname", "github.example.com"], "\(command)")
            #expect(family.repair.command == "gh auth login --hostname github.example.com", "\(command)")
        }
        // OWNER/REPO, github.com, or a value that is not HOST/OWNER/REPO keeps the default.
        for command in [
            "gh pr list -R team/app", "gh pr list --repo github.com/team/app", "GH_REPO=team/app gh pr list",
            "gh pr list --repo 'x;rm/team/app'", "gh pr list --repo github.example.com/team/app/extra"
        ] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub, "\(command)")
        }
        // The launch's GH_REPO retargets the default check, after GH_HOST.
        var projected = CLISessionExpiryClassifier.gitHub.repair
        projected.checkEnvironment = ["GH_REPO": "github.example.com/team/app"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).checkArguments?.last == "github.example.com")
        projected.checkEnvironment = ["GH_REPO": "team/app"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).checkArguments?.last == "github.com")
    }

    @Test("A CLI the agent ran by path is checked and signed in at that path")
    func exactExecutableIsCarried() throws {
        let output = "HTTP 401: Bad credentials (https://api.github.com/user)"
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: "/opt/team/bin/gh api user"))
        let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message))
        #expect(family.repair.checkBinary == "/opt/team/bin/gh")
        #expect(family.repair.command == "/opt/team/bin/gh auth login")
        #expect(RepairAction.isSafeTerminalCommand(try #require(family.repair.command), binary: "/opt/team/bin/gh", allowsInstaller: false))
        // With an Enterprise host, both survive the stop message.
        let hosted = try #require(CLISessionExpiryClassifier.family(forStopMessage: CLISessionExpiryClassifier.stop(
            content: output, command: "/opt/team/bin/gh api user --hostname github.example.com"
        )?.message))
        #expect(hosted.repair.command == "/opt/team/bin/gh auth login --hostname github.example.com")
        #expect(hosted.repair.checkArguments == ["auth", "status", "--hostname", "github.example.com"])
        // A check-only family names the path in the check its message describes.
        let token = try #require(CLISessionExpiryClassifier.family(
            content: "The token in GH_TOKEN is invalid.", command: "env /opt/team/bin/gh pr list"
        ))
        #expect(token.repair.checkBinary == "/opt/team/bin/gh")
        #expect(token.stopMessage.contains("`/opt/team/bin/gh auth status --hostname github.com`"))
        #expect(CLISessionExpiryClassifier.family(forStopMessage: token.stopMessage) == token)
        let cloud = try #require(CLISessionExpiryClassifier.family(content: gcloudReauth, command: "/opt/sdk/bin/gcloud projects list"))
        #expect(cloud.repair.checkBinary == "/opt/sdk/bin/gcloud")
        #expect(cloud.repair.checkExpect == SemanticCheck.stdoutNonEmpty.rawValue)
        #expect(CLISessionExpiryClassifier.family(forStopMessage: cloud.stopMessage) == cloud)
        // A bare name, disagreeing paths, or a path unsafe as one word stay on PATH.
        for command in [
            "gh api user", "/opt/a/gh api user && /opt/b/gh api user", "\"/opt/my tools/gh\" api user",
            "/opt/../tmp/gh api user", "./gh api user",
            // A path the agent could have just written is never run by Resume
            // or Sign in: home, workspace and temporary folders.
            "/tmp/x/gh api user", "/private/var/folders/ab/T/gh api user", "/Users/someone/work/gh api user"
        ] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub, "\(command)")
        }
    }

    @Test("bq or gsutil run by path is checked and signed in with the gcloud beside it")
    func companionPathRetargetsToSiblingGcloud() throws {
        let sdk = "/opt/google-cloud-sdk/bin"
        let installed: (String) -> Bool = { $0 == "\(sdk)/gcloud" }
        for command in ["\(sdk)/bq query 'select 1'", "\(sdk)/gsutil ls gs://bucket"] {
            let family = try #require(CLISessionExpiryClassifier.family(content: gcloudReauth, command: command, isExecutable: installed))
            #expect(family.repair.checkBinary == "\(sdk)/gcloud", "\(command)")
            #expect(family.repair.command == "\(sdk)/gcloud auth login", "\(command)")
            #expect(family.repair.checkExpect == SemanticCheck.stdoutNonEmpty.rawValue)
            #expect(CLISessionExpiryClassifier.family(forStopMessage: family.stopMessage) == family, "\(command)")
        }
        // No gcloud beside it (a standalone gsutil), disagreeing companions,
        // or a gcloud the line runs by name: checked by name on PATH.
        for command in [
            "/usr/local/bin/gsutil ls gs://bucket",
            "\(sdk)/bq ls; /opt/other-sdk/bin/gsutil ls",
            "gcloud config list && \(sdk)/bq ls"
        ] {
            let family = try #require(CLISessionExpiryClassifier.family(content: gcloudReauth, command: command, isExecutable: installed))
            #expect(family.repair.checkBinary == "gcloud", "\(command)")
        }
    }

    @Test("Sign in runs against the credential store the resumed task reads, carrying no token")
    @MainActor
    func signInTargetsProjectedCredentialStore() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workspace = Workspace(name: "Cloud Config", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Projects", goal: "List Google Cloud projects", workspace: workspace, runtime: .claudeCode)
        task.skillSnapshots = [SkillSnapshotConfig(
            id: UUID().uuidString, name: "Cloud Agent", icon: "cloud", description: "Google Cloud projects",
            allowedTools: ["Bash"], disallowedTools: [], customTools: [], behaviorInstructions: "",
            environmentKeys: ["CLOUDSDK_CONFIG", "CLOUDSDK_AUTH_ACCESS_TOKEN"],
            environmentValues: ["/tmp/task gcloud", "ya29.secret"], isGlobal: false,
            connectorIDs: nil, localToolIDs: nil, connectorSnapshots: nil, localToolSnapshots: nil,
            createdAt: Date(), updatedAt: Date()
        )]
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let repair = CLISessionExpiryClassifier.googleCloud.repair
        let events = [snapshot(task, run, TaskEventTypes.System.runtimeRepairRequired, repair.encoded())]

        let targeted = try #require(TaskRunStopEvidence.signInRepair(events: events, runID: run.id, task: task))
        #expect(targeted.command == "env CLOUDSDK_CONFIG='/tmp/task gcloud' gcloud auth login")
        let launcher = RecordingTerminal()
        RepairActionRunner.run(targeted, terminal: launcher)
        #expect(launcher.launched == ["env CLOUDSDK_CONFIG='/tmp/task gcloud' gcloud auth login"])
        #expect(!launcher.launched.joined().contains("ya29"))
        // The dock's Sign in is the one that resolves it.
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/TaskMainView.swift"), encoding: .utf8)
        #expect(view.contains("RepairActionRunner.run(TaskRunStopEvidence.signInRepair(events: sortedEvents, runID: latestRun?.id, task: task))"))

        // Only ASTRA's own sign-in may lead with selectors, and only selectors.
        let command = try #require(targeted.command)
        #expect(!RepairAction.isSafeTerminalCommand(command, binary: "gcloud", allowsInstaller: false))
        for unsafe in [
            "env CLOUDSDK_AUTH_ACCESS_TOKEN='x' gcloud auth login", "env CLOUDSDK_CONFIG='/x' rm -rf ~",
            "env CLOUDSDK_CONFIG=/x gcloud auth login", "env gcloud auth login"
        ] {
            #expect(!RepairAction.isSafeTerminalCommand(unsafe, binary: "gcloud", allowsInstaller: false, allowsStoreSelectors: true), "\(unsafe)")
        }
        // No selector, or one that can't be quoted, leaves the command as is.
        #expect(repair.targetingCredentialStore(["CLOUDSDK_AUTH_ACCESS_TOKEN": "x"]) == repair)
        #expect(repair.targetingCredentialStore(["CLOUDSDK_CONFIG": "/a\nb"]) == repair)
        withExtendedLifetime(container) {}
    }

    @Test("A credential-store path with an apostrophe is quoted, not dropped, and the shell reads it back exactly")
    func signInQuotesApostrophesInStorePaths() throws {
        let store = "/Users/O'Connor/.config/gh"
        let repair = CLISessionExpiryClassifier.gitHub.repair
        let targeted = repair.targetingCredentialStore(["GH_CONFIG_DIR": store, "GH_HOST": "it's"])
        let command = try #require(targeted.command)
        #expect(command == #"env GH_CONFIG_DIR='/Users/O'\''Connor/.config/gh' GH_HOST='it'\''s' gh auth login"#)
        #expect(RepairAction.isSafeTerminalCommand(command, binary: "gh", allowsInstaller: false, allowsStoreSelectors: true))
        // A bare apostrophe that would end the value early is still refused.
        #expect(!RepairAction.isSafeTerminalCommand(
            "env GH_CONFIG_DIR='/a'b' gh auth login", binary: "gh", allowsInstaller: false, allowsStoreSelectors: true
        ))
        // The shell takes the quoted prefix as exactly the stored path.
        let probe = try #require(RepairAction(
            strategy: .terminal, componentName: "probe", title: "probe", verb: "Sign in", detail: "",
            command: "printenv GH_CONFIG_DIR"
        ).targetingCredentialStore(["GH_CONFIG_DIR": store]).command)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", probe]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == store + "\n")
    }

    @Test("Sign in signs in to the Enterprise host the launch's GH_REPO or GH_HOST selects, the host Resume checks")
    @MainActor
    func signInTargetsLaunchSelectedHost() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workspace = Workspace(name: "Enterprise", primaryPath: NSTemporaryDirectory())
        context.insert(workspace)
        let repair = CLISessionExpiryClassifier.gitHub.repair
        for (key, value, expected) in [
            ("GH_REPO", "github.example.com/team/app", "gh auth login --hostname github.example.com"),
            ("GH_HOST", "github.example.com", "env GH_HOST='github.example.com' gh auth login --hostname github.example.com")
        ] {
            let task = AgentTask(title: "PRs", goal: "List GitHub Enterprise pull requests", workspace: workspace, runtime: .claudeCode)
            task.skillSnapshots = [SkillSnapshotConfig(
                id: UUID().uuidString, name: "Enterprise Agent", icon: "lock", description: "GitHub Enterprise",
                allowedTools: ["Bash"], disallowedTools: [], customTools: [], behaviorInstructions: "",
                environmentKeys: [key], environmentValues: [value], isGlobal: false,
                connectorIDs: nil, localToolIDs: nil, connectorSnapshots: nil, localToolSnapshots: nil,
                createdAt: Date(), updatedAt: Date()
            )]
            context.insert(task)
            let run = TaskRun(task: task)
            context.insert(run)
            let events = [snapshot(task, run, TaskEventTypes.System.runtimeRepairRequired, repair.encoded())]

            let targeted = try #require(TaskRunStopEvidence.signInRepair(events: events, runID: run.id, task: task))
            #expect(targeted.command == expected, "\(key)")
            #expect(targeted.detail.contains("`gh auth login --hostname github.example.com`"), "\(key)")
            #expect(targeted.checkArguments == ["auth", "status", "--hostname", "github.example.com"], "\(key)")
            let command = try #require(targeted.command)
            #expect(RepairAction.isSafeTerminalCommand(command, binary: "gh", allowsInstaller: false, allowsStoreSelectors: true))
            let launcher = RecordingTerminal()
            RepairActionRunner.run(targeted, terminal: launcher)
            #expect(launcher.launched == [expected], "\(key)")
        }
        // A github.com repository keeps the default sign-in.
        var projected = repair
        projected.checkEnvironment = ["GH_REPO": "team/app"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).command == "gh auth login")
        withExtendedLifetime(container) {}
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

    @Test("A backgrounded CLI's failure is masked, even with nothing after it")
    func trailingBackgroundMasksTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["gh auth status &", "gcloud projects list 2>&1 &", "(gh auth status) &", "{ gh auth status; } &"] {
            let content = command.hasPrefix("gcloud") ? gcloudReauth : ghLoggedOut
            #expect(CLISessionExpiryClassifier.stop(content: content, command: command, failed: false) != nil, "missed: \(command)")
        }
        // A trailing `;` leaves the CLI's status the line's.
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "gh auth status;", failed: false) == nil)
    }

    @Test("A CLI in a brace group runs, and the operator after the group decides whether it is masked")
    func braceGroupsRunTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["{ gh auth status; }", "{ gh auth status; } 2>&1", "cd /tmp && { gh auth status; }"] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "not run: \(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "missed failed: \(command)")
            // The group exits with gh's status: a success is not masked.
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) == nil, "stopped: \(command)")
        }
        for command in ["{ gh auth status; } || true", "{ gh auth status; } 2>&1 | cat", "{ echo start; gh auth status; echo end; }"] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "missed: \(command)")
        }
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "{ echo gh; }"))
    }

    @Test("gh calls that name different hosts leave the stop untargeted")
    func disagreeingGitHubHostsStayUntargeted() throws {
        let output = "HTTP 401: Bad credentials (https://second.example.com/api/v3/user)"
        for command in [
            "gh auth status --hostname first.example; gh auth status --hostname second.example.com",
            "gh api user; gh api user --hostname second.example.com",
            "GH_HOST=first.example gh api user && gh pr list -R second.example.com/team/app"
        ] {
            #expect(CLISessionExpiryClassifier.gitHubHost(in: command) == nil, "\(command)")
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub, "\(command)")
        }
        // Calls that agree keep their host.
        let agreeing = "gh auth status --hostname second.example.com; gh api user --hostname second.example.com"
        #expect(CLISessionExpiryClassifier.gitHubHost(in: agreeing) == "second.example.com")
        #expect(CLISessionExpiryClassifier.gitHubHost(in: "cd /tmp && GH_HOST=second.example.com gh api user") == "second.example.com")
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

    @Test("A CLI in a shell conditional runs, and as the condition its failure is masked")
    func shellConditionalsRunAndMaskTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in [
            "if gh auth status; then echo ok; fi", "if ! gh auth status; then echo out; fi",
            "if true; then echo a; elif gh auth status; then echo b; fi",
            "while gh pr list; do sleep 1; done", "until gh auth status; do sleep 5; done",
            "if test -d .git; then if gh auth status; then echo ok; fi; fi",
            // No later command decides this line's status: the `if` does.
            "if gh auth status && echo signed-in; then :; fi"
        ] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "not run: \(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "missed failed: \(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "missed: \(command)")
        }
        // A CLI in a branch body runs too.
        #expect(CLISessionExpiryClassifier.runs("gh", in: "if test -d .git; then gh pr list; else gh repo list; fi"))
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "if true; then gh api user; fi") != nil)
        // Plain reads that quote the error, inside a conditional or not, never stop.
        for command in ["cat notes.md", "if cat notes.md; then echo ok; fi", "if grep -q 'gh auth login' notes.md; then echo; fi", "echo if gh auth status"] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) == nil, "stopped: \(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) == nil, "stopped: \(command)")
        }
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
