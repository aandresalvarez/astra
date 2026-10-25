import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Plugin source Git executable")
struct PluginSourceGitExecutableTests {
    @Test("The Apple Git launcher is resolved before entering the resource-limited helper")
    func appleLauncherUsesTheSelectedToolchainBinary() async throws {
        let lookup = await ProcessBinaryRunner().run(path: "/usr/bin/xcrun", args: ["--find", "git"],
            timeout: 10, environment: ["PATH": "/usr/bin:/bin"])
        try #require(lookup.exitCode == 0, "The selected developer tools must provide Git: \(lookup.stderr)")
        let selected = URL(fileURLWithPath: lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().path
        try #require(selected != "/usr/bin/git")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-git-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("record-helper-argument")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = PluginSourceGitRunner(helper: { helper })
        let result = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 120,
            environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .newlines) == selected)
        for explicit in ["/opt/homebrew/bin/git", "/bin/sh"] {
            let result = await runner.run(path: explicit, args: ["--version"], timeout: 120, environment: [:])
            #expect(result.stdout.trimmingCharacters(in: .newlines) == explicit)
        }
    }
    @Test("Missing or failed developer-tool lookup cannot launch an unrestricted Git")
    func lookupFailuresStayClosed() async throws {
        var missing = PluginSourceGitRunner(helper: { nil })
        missing.systemGitLookup = { _ in
            Issue.record("A missing helper must refuse before looking up Git")
            return .exited(code: 0, stdout: "/usr/bin/git", stderr: "")
        }
        #expect(await missing.run(path: "/usr/bin/git", args: [], timeout: 1, environment: [:]).launchError != nil)
        let helper = try #require(PluginSourceGitRunner.bundledHelper())
        for result in [RunResult.launchFailed("missing tools"), .exited(code: 1, stdout: "", stderr: "missing tools"),
                       .exited(code: 0, stdout: "/usr/bin/git", stderr: ""),
                       .exited(code: 0, stdout: "relative/git", stderr: "")] {
            var runner = PluginSourceGitRunner(helper: { helper })
            runner.systemGitLookup = { _ in result }
            let rejected = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 1, environment: [:])
            #expect(rejected.launchError != nil)
            #expect(rejected.stdout.isEmpty)
        }
        for result in [RunResult.timedOut(stdout: "", stderr: ""), .cancelled(stdout: "", stderr: "")] {
            var runner = PluginSourceGitRunner(helper: { helper })
            runner.systemGitLookup = { _ in result }
            let rejected = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 1, environment: [:])
            #expect(rejected.outcome == result.outcome)
        }
    }

    @Test("Only the Apple launcher needs developer-tool lookup")
    func explicitBinaryDoesNotUseTheLookup() async throws {
        var runner = PluginSourceGitRunner()
        runner.systemGitLookup = { _ in
            Issue.record("An explicit executable must remain pinned")
            return .launchFailed("unexpected lookup")
        }
        let result = await runner.run(path: "/bin/sh", args: ["-c", "printf pinned"], timeout: 5, environment: [:])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "pinned")
    }

    @Test("The caller's deadline includes developer-tool lookup")
    func lookupCannotExtendTheDeadline() async {
        var runner = PluginSourceGitRunner()
        runner.systemGitLookup = { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return .exited(code: 0, stdout: "/usr/bin/git", stderr: "")
        }
        let result = await runner.run(path: "/usr/bin/git", args: ["--version"], timeout: 0.001, environment: [:])
        // A completed lookup cannot start Git after the shared deadline,
        // even if its result would otherwise fail path admission too.
        #expect(result.timedOut)
        #expect(result.stdout.isEmpty)
    }

    @Test("Developer-tool output must name one executable Git path")
    func lookupOutputIsValidated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selected Xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("git")
        try "#!/bin/sh\nexit 0\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
        #expect(PluginSourceGitExecutable.path(from: .exited(code: 0, stdout: git.path + "\n", stderr: "")) == git.path)
        for output in ["/usr/bin/git", "relative/git", git.path + "\n/usr/bin/git", root.path, root.appendingPathComponent("missing/git").path] {
            #expect(PluginSourceGitExecutable.path(from: .exited(code: 0, stdout: output, stderr: "")) == nil)
        }
        #expect(PluginSourceGitExecutable.path(from: RunResult(outcome: .exited(code: 0), stdout: git.path,
            stderr: "", stdoutTruncated: true)) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: git.path)
        #expect(PluginSourceGitExecutable.path(from: .exited(code: 0, stdout: git.path, stderr: "")) == nil)
    }

}
