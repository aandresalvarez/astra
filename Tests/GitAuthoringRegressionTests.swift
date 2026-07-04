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
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
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

    /// Emits a PR suggestion after an optional delay, so PR-specific timeout
    /// behavior can be exercised independently of the commit path.
    private func slowCopilotPRScript(seconds: Int) -> String {
        """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        \(fakeCopilotHelpText())
        HELP
          exit 0
        fi
        sleep \(seconds)
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_PR_SUGGESTION {\\"title\\":\\"Slow PR\\",\\"body\\":\\"## Summary\\\\nDetails.\\"}"}}'
        exit 0
        """
    }

    private func makeFakeCopilotService(
        root: URL,
        script: String,
        timeoutSeconds: Int,
        pullRequestTimeoutSeconds: Int? = nil
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
        if let pullRequestTimeoutSeconds {
            service.pullRequestTimeoutSeconds = pullRequestTimeoutSeconds
        }
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

        #expect(elapsed < 30, "getStagedDiff took \(elapsed)s — possible pipe deadlock")
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

        #expect(elapsed < 30, "Expected fast helper result, took \(elapsed)s")
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

        #expect(elapsed < 30, "git reads took \(elapsed)s — possible stdin/tty block")
        #expect(url == "https://github.com/example/repo")
        #expect(status.isEmpty)
        #expect(!branch.isEmpty && branch != "unknown")
    }

    /// File operations must use `--` before pathspecs. Without it, a legitimate
    /// file whose name begins with `-` can be interpreted as a git flag.
    @Test("Stage and unstage handle pathspecs that look like flags")
    func stageAndUnstagePathspecFlagLikeFile() async throws {
        let repoPath = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let fileURL = URL(fileURLWithPath: repoPath).appendingPathComponent("--flag-like-file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        try await GitService.shared.stageFile("--flag-like-file.txt", at: repoPath)
        var files = await GitService.shared.getStatusFiles(at: repoPath)
        #expect(files.contains { $0.relativePath == "--flag-like-file.txt" && $0.isStaged })

        try await GitService.shared.unstageFile("--flag-like-file.txt", at: repoPath)
        files = await GitService.shared.getStatusFiles(at: repoPath)
        #expect(files.contains { $0.relativePath == "--flag-like-file.txt" && !$0.isStaged })
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
        #expect(elapsed < 30, "Timeout watchdog took \(elapsed)s — expected a bounded timeout")
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

    // MARK: - Pull-request timeout calibration regression

    /// The original failure: the PR draft shared the commit's short deadline and
    /// timed out before the longer markdown body could be generated. PR drafting
    /// must run on its own, larger budget — never the commit budget.
    @Test("suggestPullRequest uses its own budget, not the commit deadline")
    func pullRequestRunsOnItsOwnBudget() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-pr-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Commit budget is intentionally too short (1s) and the helper takes 2s.
        // If PR drafting wrongly reused the commit budget it would time out; the
        // PR budget (20s) must govern instead. Keep this comfortably above the
        // helper delay so full-suite process scheduling load cannot win the race.
        let service = try makeFakeCopilotService(
            root: root,
            script: slowCopilotPRScript(seconds: 2),
            timeoutSeconds: 1,
            pullRequestTimeoutSeconds: 20
        )

        let start = Date()
        let suggestion = try await service.suggestPullRequest(
            repoPath: root.path,
            branch: "feature/x",
            base: "main",
            log: "- did a thing",
            diffStat: " 1 file changed"
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(suggestion.title == "Slow PR")
        #expect(elapsed < 30, "PR draft took \(elapsed)s — expected the PR-specific budget to win")
    }

    @Test("suggestPullRequest honors its own deadline when helper is slow")
    func pullRequestHonorsItsOwnDeadline() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-git-pr-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeFakeCopilotService(
            root: root,
            script: slowCopilotPRScript(seconds: 3),
            timeoutSeconds: 30,
            pullRequestTimeoutSeconds: 1
        )

        do {
            _ = try await service.suggestPullRequest(
                repoPath: root.path,
                branch: "feature/x",
                base: "main",
                log: "- did a thing",
                diffStat: " 1 file changed"
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

    @Test("PR helper timeout records diagnostic audit fields")
    func pullRequestTimeoutLogsDiagnostics() async throws {
        let repoLabel = "git-pr-log-\(UUID().uuidString.prefix(8))"
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(repoLabel, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeFakeCopilotService(
            root: root,
            script: slowCopilotPRScript(seconds: 3),
            timeoutSeconds: 30,
            pullRequestTimeoutSeconds: 1
        )

        do {
            _ = try await service.suggestPullRequest(
                repoPath: root.path,
                branch: "feature/x",
                base: "main",
                log: "- did a thing",
                diffStat: " 1 file changed"
            )
            Issue.record("Expected providerFailed timeout error")
        } catch {
            // Expected.
        }

        AppLogger.flushForTesting()
        let log = (try? String(contentsOf: AppLogger.mainLogFile, encoding: .utf8)) ?? ""
        #expect(log.contains("git.authoring_started")
            && log.contains("operation=pull_request")
            && log.contains("repo=\(repoLabel)")
            && log.contains("timeout_seconds=1")
            && log.contains("prompt_bytes="))
        #expect(log.contains("git.authoring_failed")
            && log.contains("operation=pull_request")
            && log.contains("repo=\(repoLabel)")
            && log.contains("timed_out=true")
            && log.contains("elapsed_ms="))
    }

    /// Calibration guard: PR drafting must always be granted at least as much
    /// time as a commit subject, since its output is strictly larger.
    @Test("Default PR timeout is at least the commit timeout")
    func defaultPullRequestBudgetIsNotSmallerThanCommit() {
        let service = AgentGitAuthoringService(utilityRuntime: .claude())
        #expect(service.pullRequestTimeoutSeconds >= service.timeoutSeconds)
    }
}
