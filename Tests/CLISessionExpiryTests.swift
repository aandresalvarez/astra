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

    @Test("An unquoted # that begins a word starts a comment, to the end of the line")
    func shellCommentsRunNothing() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["cat auth.log; false # ; gh auth status", "cat auth.log #gh auth status", "true # $(gh auth token)"] {
            #expect(!CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) == nil, "\(command)")
        }
        // The next line runs; a # inside a word or quotes is text.
        #expect(CLISessionExpiryClassifier.runs("gh", in: "true # note\ngh auth status"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "echo a#b; gh auth status"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "echo '# x'; gh auth status"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "echo \"$#\"; gh auth status"))
    }

    @Test("timeout runs the CLI after its options and duration")
    func timeoutWrapsTheCLI() {
        let output = "HTTP 401: Bad credentials (https://api.github.com/user)"
        for command in [
            "timeout 30s gh api user", "timeout -s KILL 30 gh api user", "timeout --kill-after=5 -v 1m gh api user",
            "gtimeout --signal TERM 10 /opt/homebrew/bin/gh api user", "timeout -- 30 gh api user"
        ] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: output, command: command) != nil, "\(command)")
        }
        // The duration is not the command, nor is a CLI named only as an argument.
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "timeout gh api user"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "timeout 30 echo gh"))
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
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(command)")
            #expect(family.repair.command == "gh auth login --hostname github.example.com")
            #expect(RepairAction.isSafeTerminalCommand(try #require(family.repair.command), binary: "gh", allowsInstaller: false))
        }
        // github.com is checked there, named so that neither the launch nor
        // the checkout retargets it; a value that is not a host name leaves
        // the host unknown, so every host is checked.
        let named = CLISessionExpiryClassifier.family(content: output, command: "GH_HOST=github.com gh api user")
        #expect(named == CLISessionExpiryClassifier.gitHub.onHost("github.com"))
        #expect(named?.repair.command == "gh auth login --hostname github.com")
        #expect(CLISessionExpiryClassifier.family(content: output, command: "gh api user --hostname 'x;rm -rf /'")
            == CLISessionExpiryClassifier.gitHub.onEveryHost())
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
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(command)")
            #expect(family.repair.command == "gh auth login --hostname github.example.com", "\(command)")
        }
        // github.com names github.com; OWNER/REPO (the default host) or a
        // value that is not HOST/OWNER/REPO leaves it unknown: every host.
        #expect(CLISessionExpiryClassifier.family(content: output, command: "gh pr list --repo github.com/team/app")
            == CLISessionExpiryClassifier.gitHub.onHost("github.com"))
        for command in [
            "gh pr list -R team/app", "GH_REPO=team/app gh pr list",
            "gh pr list --repo 'x;rm/team/app'", "gh pr list --repo github.example.com/team/app/extra"
        ] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub.onEveryHost(), "\(command)")
        }
        // The launch's GH_REPO retargets the default check, after GH_HOST.
        var projected = CLISessionExpiryClassifier.gitHub.repair
        projected.checkEnvironment = ["GH_REPO": "github.example.com/team/app"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).checkArguments?.last == "github.example.com")
        projected.checkEnvironment = ["GH_REPO": "team/app"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(projected).checkArguments?.last == "github.com")
    }

    @Test("A host-bearing GH_REPO outranks GH_HOST, in the command and in the launch")
    func repositoryHostOutranksDefaultHost() throws {
        let output = "HTTP 401: Bad credentials (https://second.example.com/api/v3/repos/o/r/pulls)"
        for (command, host) in [
            ("GH_HOST=first.example.com GH_REPO=second.example.com/o/r gh pr list", "second.example.com"),
            ("export GH_REPO=second.example.com/o/r; GH_HOST=first.example.com gh pr list", "second.example.com"),
            ("GH_HOST=first.example.com GH_REPO=o/r gh pr list", "first.example.com"),
            ("GH_HOST=first.example.com GH_REPO=github.com/o/r gh pr list", "github.com")
        ] {
            let family = try #require(CLISessionExpiryClassifier.family(content: output, command: command), "\(command)")
            #expect(family.repair.checkArguments?.last == host, "\(command)")
            #expect(family.repair.command == "gh auth login --hostname \(host)", "\(command)")
        }
        var launch = CLISessionExpiryClassifier.gitHub.repair
        for (environment, host) in [
            (["GH_HOST": "first.example.com", "GH_REPO": "second.example.com/o/r"], "second.example.com"),
            (["GH_HOST": "first.example.com", "GH_REPO": "o/r"], "first.example.com"),
            (["GH_HOST": "first.example.com", "GH_REPO": "github.com/o/r"], "github.com")
        ] {
            launch.checkEnvironment = environment
            #expect(CLISessionExpiryClassifier.checkingLaunchHost(launch).checkArguments?.last == host, "\(environment)")
        }
        // A command that named github.com is not retargeted by the launch.
        var named = CLISessionExpiryClassifier.gitHub.onHost("github.com").repair
        named.checkEnvironment = ["GH_HOST": "first.example.com"]
        #expect(CLISessionExpiryClassifier.checkingLaunchHost(named) == named)
    }

    @Test("A gh call that names no host is checked on the host the run's checkout remotes name, or not retargeted at all")
    func checkoutHostTargetsAnUnnamedCall() async throws {
        let output = "HTTP 401: Bad credentials (https://ghe.example.com/api/v3/repos/team/app/pulls)"
        // Only a call that names no host, run where the run started, is left to the checkout.
        #expect(CLISessionExpiryClassifier.leavesGitHubHostToCheckout("gh pr list"))
        #expect(CLISessionExpiryClassifier.family(content: output, command: "gh pr list") == CLISessionExpiryClassifier.gitHub)
        for command in ["cd ../other && gh pr list", "gh pr list -R team/app", "GH_REPO=team/app gh pr list", "gh api user --hostname github.com"] {
            #expect(!CLISessionExpiryClassifier.leavesGitHubHostToCheckout(command), "\(command)")
        }
        #expect(CLISessionExpiryClassifier.family(content: output, command: "cd ../other && gh pr list") == CLISessionExpiryClassifier.gitHub.onEveryHost())

        var repair = CLISessionExpiryClassifier.gitHub.repair
        repair.checkWorkingDirectory = "/work/app"
        let enterprise = await CLISessionExpiryClassifier.checkingCheckoutHost(repair) { $0 == "/work/app" ? "GHE.example.com" : nil }
        #expect(enterprise.checkArguments == ["auth", "status", "--active", "--hostname", "ghe.example.com"])
        #expect(enterprise.command == "gh auth login --hostname ghe.example.com")
        #expect(enterprise.detail.contains("`gh auth login --hostname ghe.example.com`"))
        // Nothing read, github.com, or nothing to read from: unchanged.
        for host in [nil, "github.com"] as [String?] {
            #expect(await CLISessionExpiryClassifier.checkingCheckoutHost(repair) { _ in host } == repair)
        }
        var unread = repair
        unread.checkWorkingDirectory = nil
        #expect(await CLISessionExpiryClassifier.checkingCheckoutHost(unread) { _ in Issue.record("read"); return "ghe.example.com" } == unread)
        // A launch that selects a host, a command that named one, and a
        // rejected github.com token are not the checkout's to retarget.
        var launched = repair
        launched.checkEnvironment = ["GH_HOST": "github.com"]
        var named = CLISessionExpiryClassifier.gitHub.onHost("github.com").repair
        named.checkWorkingDirectory = "/work/app"
        var token = CLISessionExpiryClassifier.gitHubEnvironmentToken.repair
        token.checkWorkingDirectory = "/work/app"
        for candidate in [launched, named, token] {
            #expect(await CLISessionExpiryClassifier.checkingCheckoutHost(candidate) { _ in "ghe.example.com" } == candidate)
        }

        // The remotes, read offline from the checkout's own config.
        for (config, host) in [
            ("remote.origin.url\ngit@GHE.example.com:team/app.git\0", "ghe.example.com"),
            ("remote.origin.url\nhttps://ghe.example.com:8443/team/app.git\0", "ghe.example.com:8443"),
            ("remote.origin.url\nssh://git@ghe.example.com:2222/team/app.git\0remote.fork.url\nhttps://ghe.example.com/me/app\0", "ghe.example.com"),
            ("remote.origin.url\nhttps://github.com/team/app\0", "github.com")
        ] {
            #expect(GitHubCheckoutHost.host(fromConfig: config) == host, "\(config)")
        }
        for config in [
            "", "remote.origin.url\ngit@ghe.example.com:team/app.git\0remote.upstream.url\nhttps://github.com/team/app\0",
            "remote.origin.url\ngit@work-github:team/app.git\0",
            "remote.origin.url\ngit@ghe.example.com:team/app.git\0url.git@github.com:.insteadof\ngit@ghe.example.com:\0"
        ] {
            #expect(GitHubCheckoutHost.host(fromConfig: config) == nil, "\(config)")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-checkout-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        #expect(await GitHubCheckoutHost.host(workingDirectory: root.path) == nil)
        for arguments in [["init", "-q"], ["remote", "add", "origin", "git@ghe.example.com:team/app.git"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root.path] + arguments
            try git.run()
            git.waitUntilExit()
        }
        #expect(await GitHubCheckoutHost.host(workingDirectory: root.appendingPathComponent("sub").path) == "ghe.example.com")
    }

    @Test("The dock's Sign in signs in to the Enterprise host the run's checkout names")
    func dockSignInTargetsTheCheckoutHost() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-dock-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [["init", "-q"], ["remote", "add", "origin", "git@ghe.example.com:team/app.git"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root.path] + arguments
            try git.run()
            git.waitUntilExit()
        }
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workspace = Workspace(name: "Checkout", primaryPath: root.path)
        let task = AgentTask(title: "Pulls", goal: "Open a GitHub pull request", workspace: workspace, runtime: .claudeCode)
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let events = [snapshot(task, run, TaskEventTypes.System.runtimeRepairRequired, CLISessionExpiryClassifier.gitHub.repair.encoded())]
        let targeted = try #require(await TaskRunStopEvidence.signInRepair(events: events, runID: run.id, task: task))
        #expect(targeted.command == "gh auth login --hostname ghe.example.com")
        #expect(targeted.checkArguments == ["auth", "status", "--active", "--hostname", "ghe.example.com"])
    }

    @Test("Expired ADC from the run's GOOGLE_APPLICATION_CREDENTIALS file is guidance naming it, with no sign-in")
    func environmentSelectedApplicationDefaultIsNotASignIn() throws {
        let output = "ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens: ('invalid_grant: Bad Request')"
        for command in ["gcloud auth application-default print-access-token", "/opt/google-cloud-sdk/bin/gcloud auth application-default print-access-token"] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
            #expect(CLISessionExpiryClassifier.stopMessage(stop.message) { [:] } == stop.message)
            for (file, named) in [("/Users/me/keys/adc.json", true), ("/tmp/odd`name.json", false)] {
                let message = CLISessionExpiryClassifier.stopMessage(stop.message) { ["GOOGLE_APPLICATION_CREDENTIALS": file] }
                #expect(message.contains("GOOGLE_APPLICATION_CREDENTIALS"))
                #expect(message.contains("`\(file)`") == named, "\(file)")
                let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: message), "lost: \(command) \(file)")
                #expect(!family.offersSignIn)
                #expect(family.repair.command == nil)
                #expect(family.repair.verb == "Check")
                #expect(family.repair.checkArguments == CLISessionExpiryClassifier.googleCloudApplicationDefault.checkArguments)
                #expect(family.repair.checkBinary == (command.hasPrefix("/") ? "/opt/google-cloud-sdk/bin/gcloud" : "gcloud"))
            }
        }
        // A sign-in recorded before the variable was known runs nothing once it is.
        var recorded = CLISessionExpiryClassifier.googleCloudApplicationDefault.repair
        #expect(CLISessionExpiryClassifier.checkingCredentialFile(recorded) == recorded)
        recorded.checkEnvironment = ["GOOGLE_APPLICATION_CREDENTIALS": "/Users/me/keys/adc.json"]
        let guidance = CLISessionExpiryClassifier.checkingCredentialFile(recorded)
        #expect(guidance.command == nil)
        #expect(guidance.detail.contains("`/Users/me/keys/adc.json`"))
        #expect(guidance.checkEnvironment == recorded.checkEnvironment)
        // The CLI account's own sign-in is unaffected by the variable.
        var account = CLISessionExpiryClassifier.googleCloud.repair
        account.checkEnvironment = recorded.checkEnvironment
        #expect(CLISessionExpiryClassifier.checkingCredentialFile(account) == account)
        // The stop records the guidance, not the sign-in.
        let service = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Services/Runtime/RuntimeTurnOutcomeService.swift"), encoding: .utf8)
        #expect(service.contains("CLISessionExpiryClassifier.stopMessage(message) {"))
        #expect(service.contains("CLISessionExpiryClassifier.family(forStopMessage: payload), family.offersSignIn"))
    }

    @Test("An exported GH_HOST or GH_REPO targets the gh calls after it in the same shell scope")
    func exportedHostIsCarried() throws {
        let output = "HTTP 401: Bad credentials (https://github.example.com/api/v3/user)"
        for command in [
            "export GH_HOST=github.example.com; gh api user", "export GH_HOST=github.example.com\ngh api user",
            "export GH_REPO=github.example.com/team/app && gh pr list", "export UNRELATED=1 GH_HOST=github.example.com; gh api user",
            "( export GH_HOST=github.example.com; gh api user )", "export GH_HOST=github.example.com; echo \"$(gh api user)\""
        ] {
            let family = try #require(CLISessionExpiryClassifier.family(content: output, command: command), "missed: \(command)")
            #expect(family.repair.command == "gh auth login --hostname github.example.com", "\(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(command)")
        }
        // Not past its subshell, not after `unset`, not before the export,
        // and an inline assignment or flag still wins.
        for (command, host) in [
            ("( export GH_HOST=github.example.com ); gh api user", "github.com"),
            ("echo $(export GH_HOST=github.example.com); gh api user", "github.com"),
            ("export GH_HOST=github.example.com; unset GH_HOST; gh api user", "github.com"),
            ("gh api user; export GH_HOST=github.example.com", "github.com"),
            ("export GH_HOST=github.example.com; GH_HOST=other.example.com gh api user", "other.example.com"),
            ("export GH_HOST=github.example.com; gh api user --hostname other.example.com", "other.example.com")
        ] {
            let family = try #require(CLISessionExpiryClassifier.family(content: output, command: command), "missed: \(command)")
            #expect(family.repair.checkArguments?.last == host, "\(command)")
        }
    }

    @Test("The ADC check passes on a refreshed credential that prints nothing, and fails when the refresh fails")
    func applicationDefaultCheckIsItsExitStatus() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-adc-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gcloud = root.appendingPathComponent("gcloud")
        // Like `print-access-token --format=none`: no output; the exit status
        // says whether the refresh worked. Any other arguments fail.
        func install(exitCode: Int) throws {
            let script = "#!/bin/sh\n[ \"$*\" = \"auth application-default print-access-token --format=none\" ] || exit 9\nexit \(exitCode)\n"
            try script.write(to: gcloud, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gcloud.path)
        }
        var repair = CLISessionExpiryClassifier.googleCloudApplicationDefault.repair
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        try install(exitCode: 0)
        #expect(await PluginRepairCoordinator.liveCheck(repair))
        try install(exitCode: 1)
        #expect(await PluginRepairCoordinator.liveCheck(repair) == false)
        // The credential-file guidance checks the same way.
        repair = CLISessionExpiryClassifier.googleCloudApplicationDefault.credentialFile("/tmp/adc.json").repair
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        try install(exitCode: 0)
        #expect(await PluginRepairCoordinator.liveCheck(repair))
    }

    @Test("Expired Application Default Credentials are repaired and checked as ADC, not as the CLI's account")
    func applicationDefaultCredentialsAreTheirOwnSignIn() throws {
        let output = "ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens: ('invalid_grant: Bad Request')"
        for command in [
            "gcloud auth application-default print-access-token", "TOKEN=$(gcloud auth application-default print-access-token --quiet)",
            "/opt/google-cloud-sdk/bin/gcloud auth application-default print-access-token"
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "missed: \(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            let repair = family.repair
            #expect(repair.command?.hasSuffix("gcloud auth application-default login") == true, "\(command)")
            #expect(repair.checkArguments == ["auth", "application-default", "print-access-token", "--format=none"])
            // Its exit status is the answer: it prints nothing.
            #expect(repair.checkExpect == nil)
            #expect(HealthCheckPolicy.isReadOnly(binary: try #require(repair.checkBinary), arguments: try #require(repair.checkArguments)))
            #expect(RepairAction.isSafeTerminalCommand(try #require(repair.command), binary: repair.checkBinary, allowsInstaller: false))
        }
        // The CLI's own account, or a command that also makes other Google
        // Cloud calls, keeps the ordinary sign-in.
        for command in [
            "gcloud projects list", "gcloud auth application-default print-access-token; bq ls",
            "gcloud config get-value project && gcloud auth application-default print-access-token"
        ] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.googleCloud, "\(command)")
        }
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
        #expect(hosted.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"])
        // A check-only family names the path in the check its message describes.
        let token = try #require(CLISessionExpiryClassifier.family(
            content: "The token in GH_TOKEN is invalid.", command: "env /opt/team/bin/gh pr list"
        ))
        #expect(token.repair.checkBinary == "/opt/team/bin/gh")
        #expect(token.stopMessage.contains("`/opt/team/bin/gh auth status --active --hostname github.com`"))
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
    func signInTargetsProjectedCredentialStore() async throws {
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

        let targeted = try #require(await TaskRunStopEvidence.signInRepair(events: events, runID: run.id, task: task))
        #expect(targeted.command == "env CLOUDSDK_CONFIG='/tmp/task gcloud' gcloud auth login")
        let launcher = RecordingTerminal()
        RepairActionRunner.run(targeted, terminal: launcher)
        #expect(launcher.launched == ["env CLOUDSDK_CONFIG='/tmp/task gcloud' gcloud auth login"])
        #expect(!launcher.launched.joined().contains("ya29"))
        // The dock's Sign in is the one that resolves it.
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/TaskMainView.swift"), encoding: .utf8)
        #expect(view.contains("RepairActionRunner.run(await TaskRunStopEvidence.signInRepair(events: sortedEvents, runID: latestRun?.id, task: task))"))

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
    func signInTargetsLaunchSelectedHost() async throws {
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

            let targeted = try #require(await TaskRunStopEvidence.signInRepair(events: events, runID: run.id, task: task))
            #expect(targeted.command == expected, "\(key)")
            #expect(targeted.detail.contains("`gh auth login --hostname github.example.com`"), "\(key)")
            #expect(targeted.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(key)")
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
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(variable)")
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

    @Test("A here-document's body is text: a quoted sign-in error in it stops nothing")
    func heredocBodiesAreNotCommands() {
        let output = "$ gh auth status\nYou are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in [
            "cat <<'EOF'\n$ gh auth status\nYou are not logged into any GitHub hosts.\nEOF\necho done",
            "cat << EOF\ngh auth status; true\nEOF", "cat <<\"EOF\" > notes.md\ngh api user || true\nEOF",
            "cat <<-EOF\n\tgh auth status\n\tEOF\necho done", "cat <<A <<B\ngh auth status\nA\ngh api user\nB\ntrue",
            "x=$(cat <<EOF\ngh auth status\nEOF\n)"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: output, command: command, failed: false) == nil, "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: output, command: command, failed: true) == nil, "\(command)")
        }
        // A command after the delimiter line runs, and `<<<` is a string, not a here-document.
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cat <<EOF\nhello\nEOF\ngh auth status"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cat <<< hello\ngh auth status"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cat <<EOF\nEOF2\nEOF\ngh api user"))
        #expect(CLISessionExpiryClassifier.runs("gh", in: "cat <<-EOF\n\tbody\n\t\tEOF\ngh api user"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "cat <<EOF\n\tEOF\ngh api user\nEOF"))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: "cat <<EOF\nEOF2\ngh api user\nEOF"))
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

    @Test("gh calls that leave the failing host unknown check the active account on every host")
    func disagreeingGitHubHostsCheckEveryHost() throws {
        let output = "HTTP 401: Bad credentials (https://second.example.com/api/v3/user)"
        for command in [
            "gh auth status --hostname first.example; gh auth status --hostname second.example.com",
            "gh api user; gh api user --hostname second.example.com",
            "GH_HOST=first.example gh api user && gh pr list -R second.example.com/team/app",
            "gh api user --hostname github.com; gh api user --hostname second.example.com",
            "cd ../other && gh pr list", "gh pr list -R team/app"
        ] {
            #expect(CLISessionExpiryClassifier.gitHubHost(in: command) == nil, "\(command)")
            // Not github.com, nor any one host: one could pass while another fails.
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "\(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(family == CLISessionExpiryClassifier.gitHub.onEveryHost(), "\(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--active"])
            #expect(family.repair.command == "gh auth login")
            #expect(stop.message.contains("`gh auth status --active`"))
            // Neither the launch nor the checkout narrows it to one host.
            var repair = family.repair
            repair.checkEnvironment = ["GH_HOST": "second.example.com"]
            repair.checkWorkingDirectory = "/work/app"
            #expect(CLISessionExpiryClassifier.checkingLaunchHost(repair) == repair)
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
