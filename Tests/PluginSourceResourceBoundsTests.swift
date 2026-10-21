import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Plugin source subprocess bounds")
struct PluginSourceResourceBoundsTests {
    @Test("Git metadata is refused before tree traversal when final expanded bytes exceed the budget")
    func expandedMetadataIsBounded() {
        #expect(PluginSourceObjectBudget.admits("abc tree 10\ndef blob 20\n", maximumObjects: 2, maximumBytes: 30))
        for metadata in ["abc tree 31\n", "abc tree 20\ndef blob 20\n", "abc blob -1\n", "abc tree missing\n", ""] {
            #expect(!PluginSourceObjectBudget.admits(metadata, maximumObjects: 2, maximumBytes: 30))
        }
        #expect(!PluginSourceObjectBudget.admits("abc tree 1\ndef tree 1\n", maximumObjects: 1, maximumBytes: 30))
    }

    @Test("A missing resource helper never falls back to unrestricted Git")
    func missingHelperRefusesExecution() async {
        let runner = PluginSourceGitRunner(helper: { nil })
        let result = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 120, environment: [:])
        #expect(result.launchError != nil)
        #expect(result.stdout.isEmpty)
    }

    @Test("The shipped helper enforces limits before executing real Git")
    func actualHelperRunsGitUnderLimits() async throws {
        _ = try #require(PluginSourceGitRunner.bundledHelper(), "SwiftPM must build the private fetch product at \(PluginSourceGitRunner.bundledHelperURL.path)")
        let runner = PluginSourceGitRunner()
        let result = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 120, environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.exitCode == 0, "\(result.stderr) \(result.launchError ?? "")")
        #expect(result.stdout.hasPrefix("git version"))
        let limits = await runner.run(path: "/bin/sh", args: ["-c", "ulimit -t; ulimit -f; ulimit -v"], timeout: 120, environment: [:])
        #expect(limits.exitCode == 0)
        let lines = limits.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == "120")
        #expect(!limits.stdout.contains("unlimited"))
    }

    @Test("An output flood stops the subprocess rather than waiting for its deadline")
    func outputLimitTerminatesTheWriter() async {
        let result = await ProcessBinaryRunner().run(path: "/bin/sh",
            args: ["-c", "printf 1234567890; sleep 600"], timeout: 120,
            environment: [:], currentDirectory: nil, maximumOutputBytes: 4,
            terminateProcessGroup: true, stopOnOutputLimit: true)
        #expect(result.stdout == "1234")
        #expect(result.stdoutTruncated)
        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.exitCode != 0)
    }
}
