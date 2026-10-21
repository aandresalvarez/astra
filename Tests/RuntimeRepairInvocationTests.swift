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

    @Test("Complex shell diagnostics offer manual review without an inferred executable check")
    func compoundInvocationIsManual() throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(content: output,
            command: "cd /other/repo && gh api user"))
        #expect(stop.repairContext?.offersAction == false)
        #expect(stop.repairContext?.repair.command == nil)
        #expect(stop.repairContext?.repair.checkBinary == nil)
    }

    @Test("Oversized command or diagnostic does not enter the shell classifier")
    func boundedInput() {
        #expect(CLISessionExpiryClassifier.stop(content: output, command: String(repeating: " ", count: 9_000) + "gh api user") == nil)
        #expect(CLISessionExpiryClassifier.stop(content: String(repeating: "x", count: 70_000) + output, command: "gh api user") == nil)
    }
}
