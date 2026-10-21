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
            if command.hasPrefix("cd ") {
                #expect(stop?.repairContext?.offersAction == false)
                #expect(stop?.repairContext?.repair.checkBinary == nil)
            } else {
                #expect(stop?.message.contains("gcloud auth login") == true)
            }
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

    @Test("A process substitution's CLI runs, and the command it feeds decides the status")
    func processSubstitutionsMaskTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["cat <(gh auth status)", "diff <(gh api a) <(gh api b)", "gh auth status > >(tee log.txt)", "echo x | tee >(gh api user)"] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command) || command.hasPrefix("gh"), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil || command.hasPrefix("gh"), "\(command)")
        }
        #expect(CLISessionExpiryClassifier.masksExitStatus(of: "gh", in: "cat <(gh auth status)"))
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "cat <(gh auth status)") != nil)
        #expect(!CLISessionExpiryClassifier.masksExitStatus(of: "gh", in: "gh auth status < notes.txt"))
    }

    @Test("A sh, bash or zsh -c payload's commands run, in the shell's place")
    func shellPayloadsRun() throws {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in [
            "bash -lc 'gh auth status'", "sh -c \"gh api user\"", "zsh -c 'cd repo && gh pr list'",
            "bash -o pipefail -c 'gh api user | jq .'", "env -i bash -c 'gh auth status'", "/bin/bash -ec 'gh auth status'"
        ] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "\(command)")
        }
        // Masked inside the payload, or by what follows the shell.
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "bash -c 'gh auth status; true'", failed: false) != nil)
        #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: "bash -c 'gh auth status' | cat", failed: false) != nil)
        // Text, or a script file, is not a payload.
        for command in ["bash -c 'echo gh auth status'", "bash script.sh gh", "bash -x gh", "echo bash -c 'gh auth status'"] {
            #expect(!CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
        }
        // Its exports stay inside it, and reach its own later calls.
        let output = "HTTP 401: Bad credentials (https://ghe.example.com/api/v3/user)"
        let family = try #require(CLISessionExpiryClassifier.family(content: output, command: "bash -c 'export GH_HOST=ghe.example.com; gh api user'"))
        #expect(family.repair.checkArguments?.last == "ghe.example.com")
        let outside = try #require(CLISessionExpiryClassifier.family(content: output, command: "bash -c 'export GH_HOST=ghe.example.com'; gh api user"))
        #expect(outside.repair.checkArguments?.last == "github.com")
    }

    @Test("A failed line stops only when the CLI's own failure could be the line's")
    func failedLinesCorrelateWithTheCLI() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in [
            "gh --version; cat incident.txt; false", "gh auth status; cat notes.md", "gh auth status || cat notes.md", "! gh auth status",
            "echo \"$(gh auth token)\"; false", "cat <<EOF\n$(gh auth status)\nEOF\nfalse"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) == nil, "\(command)")
        }
        for command in [
            "gh api user", "gh api user && echo ok", "gh api user | jq .", "cd repo && gh pr list",
            "curl -H \"Authorization: Bearer $(gh auth token)\" https://api.github.com", "{ gh auth status; } 2>&1", "if true; then gh api user; fi"
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "\(command)")
        }
    }

    @Test("A call that &&, || or a branch may have skipped counts only when the line shows it ran")
    func shortCircuitedCallsMustHaveRun() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        // `false` skipped gh: the error is cat's output, failed or not.
        for (command, failed) in [
            ("cat incident.txt; false && gh api user", true), ("cat incident.txt; false && gh api user; true", false),
            ("gh auth status; false && gh api user", true), ("cat incident.txt; false && (cd repo; gh api user)", true),
            ("cat incident.txt; false && echo \"$(gh auth token)\"", false),
            // A skipped `||` call or branch leaves a success: the `&&` after it runs.
            ("true || gh api user && cat incident.txt && false", true),
            ("if test -d .git; then gh api user; fi && cat incident.txt && false", true),
            // And whatever runs after the skip, or in another branch, may print it.
            ("cd repo && gh api user; cat incident.txt; true", false),
            ("cat incident.txt; if test -d .git; then gh api user; fi; true", false),
            ("if test -d .git; then gh api user; else cat incident.txt; fi; true", false),
            ("cd repo && gh api user || { echo \"$NOTE\"; exit 1; }", true)
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: failed) == nil, "\(command)")
        }
        // Only quiet commands could have run without it, the rest only with
        // it: the error is its own.
        for (command, failed) in [
            ("false && gh api user", true), ("mkdir -p out && cd out && gh api user", true), ("false || gh api user", true),
            ("test -d .git && gh api user | jq .", false), ("cd repo && gh api user && echo ok", true),
            ("cd repo && gh api user; true", false), ("cd repo && gh api user || exit 1", true),
            ("if test -d .git; then gh api user; echo done; fi", false), ("if test -d .git; then gh auth status; fi", true),
            ("if test -f .skip; then :; elif gh auth status; then echo signed-in; fi", false),
            ("false && echo \"$(gh auth token)\"", false), ("cd repo && (export X=1; gh api user)", true)
        ] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: failed) != nil, "\(command)")
        }
    }

    @Test("An unquoted here-document's substitutions run; a quoted one's are text")
    func heredocSubstitutionsRun() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["cat <<EOF\n$(gh auth status)\nEOF", "cat <<EOF > out.txt\nstatus: `gh auth status`\nEOF", "cat <<-EOF\n\t$(gh api user)\n\tEOF"] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "\(command)")
        }
        for command in ["cat <<'EOF'\n$(gh auth status)\nEOF", "cat <<\"EOF\"\n$(gh auth status)\nEOF", "cat <<\\EOF\n$(gh auth status)\nEOF", "cat <<EOF\n\\$(gh auth status)\nEOF"] {
            #expect(!CLISessionExpiryClassifier.runs("gh", in: command), "\(command)")
        }
    }

    @Test("What a shell runs under reaches the commands of its payload")
    func shellPayloadsCarryTheirWrapperAssignments() throws {
        let output = "HTTP 401: Bad credentials"
        let selected = try #require(CLISessionExpiryClassifier.family(content: output, command: "env GH_CONFIG_DIR=/tmp/team bash -c 'gh api user'"))
        #expect(selected.repair.checkSelectors == ["GH_CONFIG_DIR": "/tmp/team"])
        let exported = try #require(CLISessionExpiryClassifier.family(content: output, command: "export GH_CONFIG_DIR=/tmp/team; gh api user"))
        #expect(exported.repair.checkSelectors == ["GH_CONFIG_DIR": "/tmp/team"])
        for command in ["GH_TOKEN=abc bash -c 'gh api user'", "env -u GH_TOKEN sh -c 'gh api user'"] {
            let family = try #require(CLISessionExpiryClassifier.family(content: output, command: command), "\(command)")
            #expect(!family.offersSignIn, "\(command)")
            #expect(family.repair.checkBinary == nil, "\(command)")
        }
        // Its own reserved words still read as its own.
        #expect(CLISessionExpiryClassifier.stop(content: output, command: "env X=1 bash -c '! gh api user'", failed: false) != nil)
    }

    @Test("Variables env removes, and gcloud's own account flags, leave the repair check-free and with no sign-in")
    func removedVariablesAndAccountFlagsAreNotReproduced() throws {
        let ghOutput = "HTTP 401: Bad credentials"
        let gcloudExpired = "ERROR: (gcloud.projects.list) Reauthentication required."
        for (command, output, named) in [
            ("env -u GH_TOKEN gh api user", ghOutput, "env -u GH_TOKEN"), ("env -i gh api user", ghOutput, "env -i"),
            ("env --unset=GH_TOKEN gh api user", ghOutput, "env -u GH_TOKEN"),
            ("gcloud projects list --account stale@example.com", gcloudExpired, "--account"),
            ("gcloud --configuration=team projects list", gcloudExpired, "--configuration"),
            ("gcloud projects list --impersonate-service-account svc@p.iam.gserviceaccount.com", gcloudExpired, "--impersonate-service-account")
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "\(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(!family.offersSignIn, "\(command)")
            #expect(family.repair.command == nil, "\(command)")
            #expect(family.repair.checkBinary == nil, "\(command)")
            #expect(stop.message.contains(named), "\(command)")
        }
        // Unrelated variables and flags change nothing.
        for (command, output) in [("env -u PAGER gh api user", ghOutput), ("gcloud projects list --project p --format=json", gcloudExpired)] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command)?.offersSignIn == true, "\(command)")
        }
    }

    @Test("A failure an `|| exit` passes on still reaches the line, and a later command's assignment substitution is masked")
    func exitFallbacksAndAssignmentSubstitutions() {
        let ghLoggedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
        for command in ["gh api user || exit 1", "gh api user || exit", "gh api user || return 2", "gh api user || { echo failed >&2; exit 1; }"] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) != nil, "\(command)")
        }
        for command in ["gh api user || exit 0", "gh api user || echo fallback", "gh api user || { echo failed; }"] {
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command) == nil, "\(command)")
        }
        // `TOKEN=$(gh …) echo ok` exits with echo's status; alone, with gh's.
        for command in ["TOKEN=$(gh auth token) echo ok", "TOKEN=\"$(gh auth token)\" curl -s x", "A=$(gh auth token) B=$(true) echo ok"] {
            #expect(CLISessionExpiryClassifier.masksExitStatus(of: "gh", in: command), "\(command)")
            #expect(CLISessionExpiryClassifier.stop(content: ghLoggedOut, command: command, failed: false) != nil, "\(command)")
        }
        #expect(!CLISessionExpiryClassifier.masksExitStatus(of: "gh", in: "TOKEN=$(gh auth token)"))
        // An assignment that ended its own command feeds nothing after it.
        #expect(!CLISessionExpiryClassifier.masksExitStatus(of: "gh", in: "TOKEN=$(gh auth token) && echo ok"))
    }

    @Test("Only a shell tool's command is classified: another tool's command input ran nothing")
    func onlyShellToolsAreClassified() {
        for name in ["Bash", "shell", "command_execution", "shellToolCall", "run_command", "run_shell_command", "bash(gh)"] {
            #expect(CLISessionExpiryClassifier.isShellTool(name), "\(name)")
        }
        for name in ["mcp__github__run", "Read", "WebFetch", "Task", "astra_host_github"] {
            #expect(!CLISessionExpiryClassifier.isShellTool(name), "\(name)")
        }
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "mcp__docs__search", id: "toolu_docs", input: ["command": "gcloud projects list"]), process: nil)
        #expect(monitor.processEvent(.toolResult(toolId: "toolu_docs", content: gcloudReauth, isError: true), process: nil) == false)
        #expect(monitor.runtimeStopReason == nil)
    }

    @Test("A credential store the failed call selected itself is carried; credentials it set itself are not checked")
    func commandLocalSelectors() throws {
        let gcloudExpired = "ERROR: (gcloud.projects.list) Reauthentication required."
        for (command, name, value) in [
            ("CLOUDSDK_CONFIG=/tmp/team gcloud projects list", "CLOUDSDK_CONFIG", "/tmp/team"),
            ("env CLOUDSDK_CONFIG=/Users/me/.config/team gcloud projects list", "CLOUDSDK_CONFIG", "/Users/me/.config/team")
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: gcloudExpired, command: command), "\(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            let repair = family.repair
            #expect(repair.checkSelectors == [name: value])
            #expect(RepairAction.decode(from: repair.encoded())?.checkSelectors == [name: value])
            let checked = repair.checking(in: ["CLOUDSDK_CONFIG": "/launch/config", "PATH": "/usr/bin"])
            #expect(checked.checkEnvironment == [name: value, "PATH": "/usr/bin"])
            #expect(checked.targetingCredentialStore(checked.checkEnvironment).command == nil)
            #expect(checked.targetingCredentialStore(checked.checkEnvironment).verb == "Check")
        }
        let gh = try #require(CLISessionExpiryClassifier.family(content: "HTTP 401: Bad credentials", command: "env GH_CONFIG_DIR=/tmp/gh gh api user"))
        #expect(gh.repair.checkSelectors == ["GH_CONFIG_DIR": "/tmp/gh"])
        // Credentials ASTRA can't carry: no sign-in and no check of another store.
        for (command, output) in [
            ("GH_TOKEN=abc gh api user", "HTTP 401: Bad credentials"),
            ("CLOUDSDK_CORE_ACCOUNT=other@x.org gcloud projects list", gcloudExpired),
            ("CLOUDSDK_CONFIG=team gcloud projects list", gcloudExpired),
            ("CLOUDSDK_CONFIG=/a gcloud projects list && CLOUDSDK_CONFIG=/b gcloud projects list", gcloudExpired)
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "\(command)")
            if command.contains(" && ") {
                #expect(stop.repairContext?.offersAction == false)
                #expect(stop.repairContext?.repair.command == nil)
                #expect(stop.repairContext?.repair.checkBinary == nil)
                continue
            }
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(!family.offersSignIn, "\(command)")
            #expect(family.repair.command == nil)
            #expect(family.repair.checkBinary == nil, "\(command)")
            #expect(stop.message.contains("chose itself"))
        }
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

    @Test("A GitHub Enterprise failure keeps its host check and requires manual sign-in")
    func gitHubEnterpriseHostIsCarried() throws {
        let output = "HTTP 401: Bad credentials (https://github.example.com/api/v3/user)"
        for command in [
            "GH_HOST=github.example.com gh api user", "env GH_HOST=GitHub.Example.com gh api user",
            "gh api user --hostname github.example.com", "gh auth token --hostname=github.example.com"
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "missed: \(command)")
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(command)")
            #expect(family.repair.command == nil)
            #expect(family.repair.verb == "Check")
            #expect(family.repair.checkBinary == "gh")
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

    @Test("An Enterprise repository selector keeps its host for verification after manual setup")
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
            #expect(family.repair.command == nil, "\(command)")
            #expect(family.repair.verb == "Check", "\(command)")
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
            if host == "github.com" {
                #expect(family.repair.command == "gh auth login --hostname github.com", "\(command)")
            } else {
                #expect(family.repair.command == nil, "\(command)")
                #expect(family.repair.verb == "Check", "\(command)")
            }
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
        #expect(enterprise.command == nil)
        #expect(enterprise.verb == "Check")
        #expect(enterprise.detail.contains("manually"))
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
        // `gh` treats an empty GH_HOST or GH_REPO as unset, in the launch
        // and in the command: the checkout still names the host.
        for environment in [["GH_HOST": ""], ["GH_REPO": ""], ["GH_HOST": "", "GH_REPO": ""]] {
            var empty = repair
            empty.checkEnvironment = environment
            let retargeted = await CLISessionExpiryClassifier.checkingCheckoutHost(empty) { _ in "ghe.example.com" }
            #expect(retargeted.checkArguments == ["auth", "status", "--active", "--hostname", "ghe.example.com"], "\(environment)")
            #expect(CLISessionExpiryClassifier.checkingLaunchHost(empty) == empty, "\(environment)")
        }
        for command in ["GH_HOST= gh pr list", "GH_REPO='' gh pr list", "export GH_HOST=ghe.example.com; GH_HOST= gh pr list", "env GH_HOST= gh pr list"] {
            #expect(CLISessionExpiryClassifier.leavesGitHubHostToCheckout(command), "\(command)")
            #expect(CLISessionExpiryClassifier.gitHubHost(in: command) == nil, "\(command)")
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.gitHub, "\(command)")
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

    @Test("The dock requires manual setup for the Enterprise host the run's checkout names")
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
        #expect(targeted.command == nil)
        #expect(targeted.verb == "Check")
        #expect(targeted.checkArguments == ["auth", "status", "--active", "--hostname", "ghe.example.com"])
    }

    @Test("Expired ADC from the run's GOOGLE_APPLICATION_CREDENTIALS file is guidance naming it, with no sign-in")
    func environmentSelectedApplicationDefaultIsNotASignIn() throws {
        let output = "ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens: ('invalid_grant: Bad Request')"
        for command in ["gcloud auth application-default print-access-token", "/opt/google-cloud-sdk/bin/gcloud auth application-default print-access-token"] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
            let captured = try #require(stop.repairContext)
            #expect(RuntimeRepairContextResolver.resolve(captured, environment: [:]) == captured)
            for (file, named) in [("/Users/me/keys/adc.json", true), ("/tmp/odd`name.json", false)] {
                let resolved = RuntimeRepairContextResolver.resolve(captured, environment: ["GOOGLE_APPLICATION_CREDENTIALS": file])
                #expect(resolved.message.contains("GOOGLE_APPLICATION_CREDENTIALS"))
                #expect(resolved.message.contains("`\(file)`") == named, "\(file)")
                #expect(!resolved.offersAction)
                #expect(resolved.repair.command == nil)
                #expect(resolved.repair.verb == "Check")
                #expect(resolved.repair.checkArguments == CLISessionExpiryClassifier.googleCloudApplicationDefault.checkArguments)
                #expect(resolved.repair.checkBinary == (command.hasPrefix("/") ? "/opt/google-cloud-sdk/bin/gcloud" : "gcloud"))
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
        // The typed failure keeps its repair when display prose changes, and
        // the run's credential file turns it into manual guidance.
        let captured = RuntimeRepairContext(providerBinary: "gcloud", message: "Localized display message",
                                            repair: CLISessionExpiryClassifier.googleCloudApplicationDefault.repair,
                                            offersAction: true)
        let resolved = RuntimeRepairContextResolver.resolve(captured, environment: recorded.checkEnvironment)
        #expect(!resolved.offersAction)
        #expect(resolved.repair.command == nil)
        #expect(resolved.message.contains("`/Users/me/keys/adc.json`"))
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
            #expect(family.repair.command == nil, "\(command)")
            #expect(family.repair.verb == "Check", "\(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(command)")
        }
        // Not past its subshell, not after `unset`, not before the export,
        // and an inline assignment or flag still wins.
        for (command, host) in [
            ("( export GH_HOST=github.example.com ); gh api user", "github.com"),
            ("echo $(export GH_HOST=github.example.com); gh api user", "github.com"),
            ("export GH_HOST=github.example.com; unset GH_HOST; gh api user", "github.com"),
            ("gh api user && export GH_HOST=github.example.com", "github.com"),
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
        // The fake lives in a temporary folder, not an installed path.
        let anywhere: @Sendable (String) -> Bool = { _ in true }
        try install(exitCode: 0)
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: anywhere))
        #expect(await PluginRepairCoordinator.liveCheck(repair) == false)
        try install(exitCode: 1)
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: anywhere) == false)
        // The credential-file guidance checks the same way.
        repair = CLISessionExpiryClassifier.googleCloudApplicationDefault.credentialFile("/tmp/adc.json").repair
        repair.checkEnvironment = ["PATH": "\(root.path):/usr/bin:/bin"]
        try install(exitCode: 0)
        #expect(await PluginRepairCoordinator.liveCheck(repair, isInstalled: anywhere))
    }

    @Test("Expired Application Default Credentials are repaired and checked as ADC, not as the CLI's account")
    func applicationDefaultCredentialsAreTheirOwnSignIn() throws {
        let output = "ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens: ('invalid_grant: Bad Request')"
        for command in [
            "gcloud auth application-default print-access-token", "TOKEN=$(gcloud auth application-default print-access-token --quiet)",
            "/opt/google-cloud-sdk/bin/gcloud auth application-default print-access-token",
            // A release track runs the same ADC command.
            "gcloud beta auth application-default print-access-token", "gcloud alpha auth application-default print-access-token --quiet",
            // gcloud-wide flags, and their values, come before the command.
            "gcloud --project team auth application-default print-access-token",
            "gcloud --verbosity debug beta auth application-default print-access-token",
            "gcloud --format=json -q --billing-project b auth application-default print-access-token",
            "gcloud --log-http --flags-file f.yaml auth application-default print-access-token"
        ] {
            let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command), "missed: \(command)")
            if command.hasPrefix("TOKEN=$(") {
                #expect(stop.repairContext?.offersAction == false)
                #expect(stop.repairContext?.repair.command == nil)
                #expect(stop.repairContext?.repair.checkBinary == nil)
                continue
            }
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
            "gcloud config get-value project && gcloud auth application-default print-access-token",
            "gcloud beta projects list", "gcloud beta auth login", "gcloud beta beta auth application-default print-access-token",
            "gcloud --project team projects list", "gcloud --quiet application-default auth list"
        ] {
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == CLISessionExpiryClassifier.googleCloud, "\(command)")
        }
        // A flag that picks the account still reads ADC: its repair checks
        // nothing it can't reproduce (`commandLocalCredentials`).
        let account = try #require(CLISessionExpiryClassifier.family(
            content: output, command: "gcloud --account me@x.org auth application-default print-access-token"
        ))
        #expect(account.readsApplicationDefault)
        #expect(account.ownCredentials == ["--account"])
        #expect(account.repair.command == nil)
        // An unknown flag may or may not take the next word: the command is
        // unknown, so neither sign-in is offered rather than the wrong one.
        for command in [
            "gcloud --mystery x auth application-default print-access-token", "gcloud --mystery auth application-default print-access-token",
            "gcloud auth --mystery application-default print-access-token"
        ] {
            #expect(CLISessionExpiryClassifier.readsOnlyApplicationDefault(command) == nil, "\(command)")
            #expect(CLISessionExpiryClassifier.family(content: output, command: command) == nil, "\(command)")
        }
        #expect(CLISessionExpiryClassifier.readsOnlyApplicationDefault("gcloud --mystery x projects list; bq ls") == false)
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
        #expect(hosted.repair.command == nil)
        #expect(hosted.repair.verb == "Check")
        #expect(hosted.repair.checkBinary == "/opt/team/bin/gh")
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
        #expect(targeted.command == nil)
        #expect(targeted.verb == "Check")
        #expect(targeted.checkEnvironment?["CLOUDSDK_CONFIG"] == "/tmp/task gcloud")
        let launcher = RecordingTerminal()
        RepairActionRunner.run(targeted, terminal: launcher)
        #expect(launcher.launched.isEmpty)
        #expect(!launcher.launched.joined().contains("ya29"))
        // The dock's actual action verifies the prepared manual repair.
        var checked: RepairAction?
        let guidance = await TaskRepairAction.perform(targeted, check: { repair in checked = repair; return false },
            run: { _ in Issue.record("A manual repair cannot launch Terminal") })
        #expect(checked?.checkEnvironment?["CLOUDSDK_CONFIG"] == "/tmp/task gcloud")
        #expect(guidance?.title == "Setup needs attention")

        // Neither source-defined nor old saved repairs may redirect a login
        // into a task-selected credential directory.
        for unsafe in [
            "env CLOUDSDK_AUTH_ACCESS_TOKEN='x' gcloud auth login", "env CLOUDSDK_CONFIG='/x' rm -rf ~",
            "env CLOUDSDK_CONFIG=/x gcloud auth login", "env gcloud auth login"
        ] {
            #expect(!RepairAction.isSafeTerminalCommand(unsafe, binary: "gcloud", allowsInstaller: false), "\(unsafe)")
        }
        // A non-selector does not redirect a login. Even malformed selected
        // directory values require manual setup.
        #expect(repair.targetingCredentialStore(["CLOUDSDK_AUTH_ACCESS_TOKEN": "x"]) == repair)
        #expect(repair.targetingCredentialStore(["CLOUDSDK_CONFIG": "/a\nb"]).command == nil)
        withExtendedLifetime(container) {}
    }

    @Test("A selected credential-store path with an apostrophe stays check-only")
    func selectedStorePathCannotReachTerminal() {
        let store = "/Users/O'Connor/.config/gh"
        let environment = ["GH_CONFIG_DIR": store, "GH_HOST": "github.example.com"]
        let repair = CLISessionExpiryClassifier.gitHub.repair.checking(in: environment)
            .targetingCredentialStore(environment)
        #expect(repair.command == nil)
        #expect(repair.verb == "Check")
        #expect(repair.checkEnvironment == environment)
        #expect(!RepairAction.isSafeTerminalCommand(
            "env GH_CONFIG_DIR='/a'b' gh auth login", binary: "gh", allowsInstaller: false
        ))
    }

    @Test("A launch-selected Enterprise host needs manual sign-in and keeps its exact Resume check")
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
        for (key, value) in [
            ("GH_REPO", "github.example.com/team/app"),
            ("GH_HOST", "github.example.com")
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
            #expect(targeted.command == nil, "\(key)")
            #expect(targeted.verb == "Check", "\(key)")
            #expect(targeted.detail.contains("manually"), "\(key)")
            #expect(targeted.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"], "\(key)")
            let launcher = RecordingTerminal()
            RepairActionRunner.run(targeted, terminal: launcher)
            #expect(launcher.launched.isEmpty, "\(key)")
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
            if command != "gh pr list -R team/app" {
                #expect(stop.repairContext?.offersAction == false)
                #expect(stop.repairContext?.repair.command == nil)
                #expect(stop.repairContext?.repair.checkBinary == nil)
                continue
            }
            let family = try #require(CLISessionExpiryClassifier.family(forStopMessage: stop.message), "lost: \(command)")
            #expect(family == CLISessionExpiryClassifier.gitHub.onEveryHost(), "\(command)")
            #expect(family.repair.checkArguments == ["auth", "status", "--active"])
            #expect(family.repair.command == nil)
            #expect(family.repair.verb == "Check")
            #expect(stop.repairContext?.offersAction == false)
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
            "if test -f .skip; then :; elif gh auth status; then echo b; fi",
            "while gh pr list; do sleep 1; done", "until gh auth status; do sleep 5; done",
            "if test -d .git; then if gh auth status; then echo ok; fi; fi",
            // No later command decides this line's status: the `if` does.
            "if gh auth status && echo signed-in; then :; fi"
        ] {
            #expect(CLISessionExpiryClassifier.runs("gh", in: command), "not run: \(command)")
            // A condition's failure never fails the line: a failed line
            // failed elsewhere, so only the succeeding line stops.
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
