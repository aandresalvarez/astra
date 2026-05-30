import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Git Authoring Regression")
struct GitAuthoringRegressionTests {

    // MARK: - Helpers

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return Int(process.terminationStatus)
    }

    private func makeTempGitRepo() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-regression-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let initCommand = """
        git init && \
        git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' \
        commit --allow-empty -m 'init'
        """
        let exitCode = runShell(initCommand, in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitAuthoringRegressionTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize temp git repo at \(path)"
            ])
        }
        return path
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fakeCopilotHelpText() -> String {
        """
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --no-custom-instructions --allow-all-tools required for non-interactive mode
        """
    }

    private func fastCopilotSuggestionScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(fakeCopilotHelpText())
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_COMMIT_SUGGESTION {\\"subject\\":\\"Fast commit\\",\\"body\\":\\"\\",\\"type\\":\\"test\\"}"}}'
        exit 0
        """
    }

    private func slowCopilotSuggestionScript(seconds: Int) -> String {
        """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(fakeCopilotHelpText())
        HELP
          exit 0
        fi
        sleep \(seconds)
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_COMMIT_SUGGESTION {\\"subject\\":\\"Slow commit\\",\\"body\\":\\"\\",\\"type\\":\\"test\\"}"}}'
        exit 0
        """
    }

    private func makeFakeCopilotService(
        root: URL,
        script: String,
        timeoutSeconds: Int
    ) throws -> AgentGitAuthoringService {
        let fakeCopilot = root.appendingPathComponent("copilot")
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try writeExecutableScript(at: fakeCopilot, contents: script)
        var service = AgentGitAuthoringService(
            utilityRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: copilotHome.path
            )
        )
        service.timeoutSeconds = timeoutSeconds
        return service
    }

    // MARK: - Pipe drain regression

    @Test("Large staged diff completes without pipe deadlock")
    func largeStagedDiffDoesNotHang() async throws {
        let repoPath = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let largeContent = String(repeating: "x", count: 100_000)
        let filePath = URL(fileURLWithPath: repoPath).appendingPathComponent("large.txt")
        try largeContent.write(to: filePath, atomically: true, encoding: .utf8)

        let addExit = runShell("git add large.txt", in: repoPath)
        #expect(addExit == 0)

        let start = Date()
        let diff = await GitService.shared.getStagedDiff(at: repoPath, limit: 200_000)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 5, "getStagedDiff took \(elapsed)s — possible pipe deadlock")
        #expect(diff.contains("diff --git"))
        #expect(!diff.isEmpty)
    }

    // MARK: - Timeout race regression

    @Test("runWithTimeout returns fast helper result without false timeout")
    func runWithTimeoutReturnsFastResult() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-timeout-fast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeFakeCopilotService(
            root: root,
            script: fastCopilotSuggestionScript(),
            timeoutSeconds: 30
        )

        let start = Date()
        let suggestion = try await service.suggestCommitMessage(
            repoPath: root.path,
            diff: "diff --git a/foo b/foo\n+line",
            recentSubjects: ["fix: prior"]
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 5, "Expected fast helper result, took \(elapsed)s")
        #expect(suggestion.subject == "Fast commit")
        #expect(suggestion.type == "test")
    }

    // MARK: - runGit no-hang regression

    /// A `git` invocation that reads stdin must not hang when ASTRA runs it.
    /// `getRemoteOriginURL` runs `git config --get …`; we use a repo configured
    /// so the call returns quickly. The real guard here is that GitService now
    /// detaches stdin and disables interactive prompts, so no git command can
    /// block waiting on a controlling terminal that does not exist in a GUI app.
    @Test("Git reads complete promptly with detached stdin")
    func gitReadsDoNotBlockOnStdin() async throws {
        let repoPath = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        _ = runShell("git remote add origin git@github.com:example/repo.git", in: repoPath)

        let start = Date()
        let url = await GitService.shared.getRemoteOriginURL(at: repoPath)
        let status = await GitService.shared.getStatusFiles(at: repoPath)
        let branch = await GitService.shared.getCurrentBranch(at: repoPath)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 5, "git reads took \(elapsed)s — possible stdin/tty block")
        #expect(url == "https://github.com/example/repo")
        #expect(status.isEmpty)
        #expect(!branch.isEmpty && branch != "unknown")
    }

    /// A push to an unreachable remote must fail fast instead of hanging on a
    /// credential/username prompt. With `GIT_TERMINAL_PROMPT=0` and a detached
    /// stdin, git aborts immediately rather than waiting for terminal input.
    @Test("Push to unreachable remote fails fast without prompting")
    func pushToBogusRemoteFailsFast() async throws {
        let repoPath = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let bogusRemote = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-nonexistent-remote-\(UUID().uuidString)")
            .path
        _ = runShell("git remote add origin file://\(bogusRemote)", in: repoPath)

        let start = Date()
        var didThrow = false
        do {
            try await GitService.shared.push(at: repoPath)
        } catch {
            didThrow = true
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(didThrow, "Push to a bogus remote should fail")
        #expect(elapsed < 15, "Push hung for \(elapsed)s — possible credential prompt block")
    }

    /// The hard timeout watchdog must kill a genuinely hung subprocess and
    /// resume promptly, so a single stuck git call can never deadlock the
    /// Repository panel (the original "spinner forever" regression).
    @Test("runProcess timeout kills a hung subprocess and resumes fast")
    func runProcessTimeoutKillsHungSubprocess() async throws {
        let start = Date()
        var didThrow = false
        do {
            _ = try await GitService.shared.runProcessForTesting(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30"],
                timeout: 1
            )
            Issue.record("Expected timeout error from hung subprocess")
        } catch {
            didThrow = true
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(didThrow, "A hung subprocess should surface a timeout error")
        #expect(elapsed < 5, "Timeout watchdog took \(elapsed)s — expected ~1s budget")
    }

    /// Even when a subprocess emits more than the OS pipe buffer (~64KB) the
    /// non-blocking drain must return the full output without wedging.
    @Test("runProcess drains output larger than the pipe buffer")
    func runProcessDrainsLargeOutput() async throws {
        let output = try await GitService.shared.runProcessForTesting(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "for i in $(seq 1 5000); do echo 0123456789012345678901234567890123456789; done"],
            timeout: 10
        )
        #expect(output.utf8.count > 200_000, "Expected large drained output, got \(output.utf8.count) bytes")
    }

    @Test("runWithTimeout honors deadline when helper is slow")
    func runWithTimeoutHonorsDeadline() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-timeout-slow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeFakeCopilotService(
            root: root,
            script: slowCopilotSuggestionScript(seconds: 3),
            timeoutSeconds: 1
        )

        do {
            _ = try await service.suggestCommitMessage(
                repoPath: root.path,
                diff: "diff --git a/foo b/foo\n+line",
                recentSubjects: []
            )
            Issue.record("Expected providerFailed timeout error")
        } catch let error as GitAuthoringError {
            if case .providerFailed(let message) = error {
                #expect(message.contains("Timed out after 1s"))
            } else {
                Issue.record("Expected providerFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
