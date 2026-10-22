import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Bounded runtime repair admission")
struct RuntimeRepairInvocationTests {
    private let output = "You are not logged into any GitHub hosts. To log in, run: gh auth login"

    @Test("A wrapper that changes directory or user never repairs ASTRA's own login", arguments: [
        "env -C /other/repo gh api user", "env --chdir=/other/repo gh api user",
        "sudo -H -u build gh api user", "sudo --user=build gh api user"
    ])
    func changedContextIsManual(command: String) throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
        let capture = try #require(stop.repairContext)
        #expect(!capture.offersAction)
        #expect(capture.repair.command == nil)
        #expect(capture.repair.checkBinary == nil)
        #expect(!stop.message.contains("Run `gh auth login`"))
    }

    @Test("Command-local executable search paths require manual repair", arguments: [
        "PATH=/opt/team/bin gh api user", "env PATH=/opt/team/bin gh api user",
        "env -u PATH gh api user", "env --unset=PATH gh api user", "env -uPATH gh api user",
        "env -i gh api user"
    ])
    func changedSearchPathIsManual(command: String) throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
        #expect(stop.repairContext?.offersAction == false)
        #expect(stop.repairContext?.repair.checkBinary == nil)
    }

    @Test("Defining a shell function does not prove its CLI ran", arguments: [
        "f() { gh api user; }; cat incident.txt", "function f { gh api user; }; cat incident.txt"
    ])
    func uninvokedFunctionDoesNotPause(command: String) {
        #expect(CLISessionExpiryClassifier.stop(content: output, command: command, failed: false) == nil)
    }

    @Test("Automatic repair admits a small direct invocation and retains its chosen host")
    func directInvocation() throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output,
            command: "GH_HOST=github.com /opt/team/bin/gh api user"))
        #expect(stop.repairContext?.offersAction == true)
        #expect(stop.repairContext?.repair.checkBinary == "/opt/team/bin/gh")
        #expect(stop.repairContext?.repair.checkArguments?.last == "github.com")
    }

    @Test("An explicit untrusted executable never repairs a different CLI on ASTRA's PATH", arguments: [
        "/tmp/plugin/gh api user", "./gh api user", "env /tmp/plugin/gh api user",
        "/tmp/wrapper/env gh api user", "/usr/local/../tmp/gh api user"
    ])
    func untrustedExecutableIsManual(command: String) throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
        #expect(stop.repairContext?.offersAction == false)
        #expect(stop.repairContext?.repair.command == nil)
        #expect(stop.repairContext?.repair.checkBinary == nil)
    }

    @Test("Complex shell diagnostics offer manual review without an inferred executable check")
    func compoundInvocationIsManual() throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output,
            command: "cd /other/repo && gh api user"))
        #expect(stop.repairContext?.offersAction == false)
        #expect(stop.repairContext?.repair.command == nil)
        #expect(stop.repairContext?.repair.checkBinary == nil)
    }

    @Test("Unsupported conditional bodies cannot attribute another command's diagnostic to a CLI", arguments: [
        "case no in yes) gh api user;; esac; cat incident.txt",
        "case no in yes) gh api user;; *) cat incident.txt;; esac",
        "if true; then case no in yes) gh api user;; esac; fi; cat incident.txt",
        "bash -c 'case no in yes) gh api user;; esac; cat incident.txt'",
        "for item in; do gh api user; done; cat incident.txt",
        "select item in; do gh api user; done; cat incident.txt"
    ])
    func unknownConditionalCannotPause(command: String) {
        #expect(!RuntimeRepairInvocationPolicy.admitsDiagnostics(command: command, content: output))
        #expect(CLISessionExpiryClassifier.stop(content: output, command: command, failed: false) == nil)
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "Bash", id: "conditional", input: ["command": command]), process: nil)
        #expect(!monitor.processEvent(.toolResult(toolId: "conditional", content: output, isError: false), process: nil))
        #expect(monitor.runtimeRepairContext == nil)
    }

    @Test("Arithmetic variables are not executable commands", arguments: [
        "cat incident.txt; (( gh ))", "(( gh + 1 )); cat incident.txt",
        "printf '%s' $((gh)); cat incident.txt", "echo \"$((gh))\"; cat incident.txt",
        "bash -c 'cat incident.txt; (( gh ))'",
        "cat <<EOF\n$((gh))\nEOF\ncat incident.txt"
    ])
    func arithmeticCannotAttributeDiagnostics(command: String) {
        #expect(!RuntimeRepairInvocationPolicy.admitsDiagnostics(command: command, content: output))
        #expect(!CLISessionExpiryClassifier.runs("gh", in: command))
        #expect(CLISessionExpiryClassifier.stop(content: output, command: command) == nil)
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "Bash", id: "arithmetic", input: ["command": command]), process: nil)
        #expect(!monitor.processEvent(.toolResult(toolId: "arithmetic", content: output, isError: true), process: nil))
        #expect(monitor.runtimeRepairContext == nil)
    }

    @Test("Literal arithmetic text and real nested subshells preserve executable attribution", arguments: [
        "printf '%s' '(( gh ))'; gh api user", "echo 'literal $(( gh ))'; gh api user",
        "( ( gh api user ) )", "gh api user # (( literal ))",
        "cat <<'EOF'\n$((gh))\nEOF\ngh api user"
    ])
    func literalsDoNotDisableRealCLI(command: String) {
        #expect(RuntimeRepairInvocationPolicy.admitsDiagnostics(command: command, content: output))
        #expect(CLISessionExpiryClassifier.runs("gh", in: command))
        #expect(CLISessionExpiryClassifier.stop(content: output, command: command) != nil)
    }

    @Test("Real shell arithmetic failure does not execute the named CLI")
    func realArithmeticVariableIsNotCLI() throws {
        let command = "unset gh; printf '%s' '\(output)'; (( gh ))"
        let result = try PermissionRepairCommandClient.run("/bin/sh", ["-c", command])
        #expect(result.exitCode == 1)
        let stdout = try #require(result.stdout)
        #expect(stdout == output)
        #expect(CLISessionExpiryClassifier.stop(content: stdout, command: command) == nil)
    }

    @Test("A real skipped case arm succeeds and its printed incident must not pause the run")
    func skippedCaseExecutesNoCLI() throws {
        let command = "case no in yes) gh api user;; esac; printf '%s' '\(output)'"
        let result = try PermissionRepairCommandClient.run("/bin/sh", ["-c", command])
        #expect(result.exitCode == 0)
        let stdout = try #require(result.stdout)
        #expect(stdout == output)
        #expect(CLISessionExpiryClassifier.stop(content: stdout, command: command, failed: false) == nil)
    }

    @Test("An untracked loop body cannot index an absent compound while checking failure propagation")
    func untrackedLoopBodyDoesNotCrash() {
        #expect(!CLISessionExpiryClassifier.failureReaches(from: "gh",
            in: "for item in; do gh api user; done; cat incident.txt"))
    }

    @Test("Control-flow words in CLI arguments do not disable a supported direct repair", arguments: [
        "gh api --field mode=case", "gh api /repos/team/case", "gh api --field mode=for"
    ])
    func literalControlWordsRemainArguments(command: String) throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output, command: command))
        #expect(stop.repairContext?.offersAction == true)
    }

    @Test("Oversized command or diagnostic does not enter the shell classifier")
    func boundedInput() {
        #expect(CLISessionExpiryClassifier.stop(content: output, command: String(repeating: " ", count: 9_000) + "gh api user") == nil)
        #expect(CLISessionExpiryClassifier.stop(content: String(repeating: "x", count: 70_000) + output, command: "gh api user") == nil)
    }
}
