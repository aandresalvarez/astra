import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeValidationServiceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private actor StubValidationCommandRunner: ValidationCommandRunning {
    struct Call: Equatable {
        let command: String
        let workingDirectory: String
        let pathContainsShellSuffix: Bool
        let additionalWritablePaths: [String]
    }

    private var results: [ValidationCommandResult]
    private var calls: [Call] = []

    init(results: [ValidationCommandResult]) {
        self.results = results
    }

    func run(command: String, workingDirectory: String, environment: [String: String], additionalWritablePaths: [String]) async -> ValidationCommandResult {
        calls.append(Call(
            command: command,
            workingDirectory: workingDirectory,
            pathContainsShellSuffix: environment["PATH"]?.contains(RuntimePathResolver.shellPathSuffix) == true,
            additionalWritablePaths: additionalWritablePaths
        ))
        return results.isEmpty
            ? ValidationCommandResult(exitCode: 0, stdout: "", stderr: "")
            : results.removeFirst()
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@Suite("Validation service")
@MainActor
struct ValidationServiceTests {
    @Test("shell validation runner uses shared process runner current directory")
    nonisolated func shellValidationRunnerUsesCurrentDirectory() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-validation-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "validation cwd".write(
            to: directory.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = await ShellValidationCommandRunner().run(
            command: "cat marker.txt",
            workingDirectory: directory.path,
            environment: ProcessInfo.processInfo.environment,
            additionalWritablePaths: []
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "validation cwd")
        #expect(result.stderr.isEmpty)
        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.elapsedTime >= 0)
    }

    @Test("shell validation runner surfaces launch failures through the shared process contract")
    nonisolated func shellValidationRunnerSurfacesMissingWorkingDirectory() async {
        let missingDirectory = NSTemporaryDirectory() + "astra-validation-missing-\(UUID().uuidString)"

        let result = await ShellValidationCommandRunner().run(
            command: "echo should-not-run",
            workingDirectory: missingDirectory,
            environment: ProcessInfo.processInfo.environment,
            additionalWritablePaths: []
        )

        #expect(result.exitCode == -1)
        #expect(result.launchError?.isEmpty == false)
        #expect(!result.stderr.isEmpty)
        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.elapsedTime >= 0)
    }

    @Test("shell validation runner now blocks an out-of-workspace write via the Seatbelt floor")
    nonisolated func shellValidationRunnerBlocksOutOfWorkspaceWrite() async throws {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        // Deliberately NOT under NSTemporaryDirectory()/$TMPDIR: decideForCommand
        // (like the agent sandbox it mirrors) always grants /tmp and $TMPDIR as
        // scratch space regardless of workspace, so a fixture rooted there could
        // never demonstrate a blocked write. /var/tmp is a distinct, normally
        // world-writable system temp directory that is NOT in that unconditional
        // grant list, so it correctly stands in for "some other real location."
        let root = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent("astra-validation-escape-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A sibling of the workspace, outside it — this is exactly the kind of
        // write a compromised conftest.py/package.json script/Makefile could
        // attempt. Before the Seatbelt floor this would silently succeed;
        // decideForCommand's write jail must now block it.
        let escapePath = root.appendingPathComponent("escaped.txt").path

        let result = await ShellValidationCommandRunner().run(
            command: "printf escape > '\(escapePath)'",
            workingDirectory: workspace.path,
            environment: ProcessInfo.processInfo.environment,
            additionalWritablePaths: []
        )

        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: escapePath))
    }

    @Test("shell validation runner grants a multi-path workspace's additional paths, not just the primary one")
    nonisolated func shellValidationRunnerGrantsAdditionalWritablePaths() async throws {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let root = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent("astra-validation-multipath-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let additional = root.appendingPathComponent("additional", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A workspace can span multiple paths (Workspace.additionalPaths); a
        // validation command run from the primary path legitimately writing
        // generated fixtures/output into one of those additional paths must
        // not be denied by the write jail.
        let outputPath = additional.appendingPathComponent("output.txt").path

        let result = await ShellValidationCommandRunner().run(
            command: "printf multipath > '\(outputPath)'",
            workingDirectory: primary.path,
            environment: ProcessInfo.processInfo.environment,
            additionalWritablePaths: [additional.path]
        )

        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outputPath))
    }

    // MARK: - Per-tool cache grant dispatch

    @Test("pytest/python get no package-manager cache grants")
    func toolCacheGrantsExcludePythonFromPackageManagerCaches() {
        for root in ["pytest", "python", "python3"] {
            #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: root, makefileMentions: []).isEmpty)
        }
    }

    @Test("npm/yarn/pnpm each get only their own cache paths, not a blanket list")
    func toolCacheGrantsAreScopedToTheInvokedTool() {
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "npm", makefileMentions: []) == [".npm"])
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "yarn", makefileMentions: []) == ["Library/Caches/Yarn", ".yarn/berry"])
        // pnpm is deliberately narrowed to the store, NOT the whole `Library/pnpm`
        // tree (which also holds pnpm's own executable/tooling — see doc comment).
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "pnpm", makefileMentions: []) == ["Library/pnpm/store"])
    }

    @Test("make grants only the caches for package managers its Makefile actually mentions")
    func makeToolCacheGrantsMatchMakefileMentions() {
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "make", makefileMentions: []).isEmpty)
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "make", makefileMentions: ["npm"]) == [".npm"])
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "make", makefileMentions: ["npm", "yarn"]).sorted() ==
            [".npm", ".yarn/berry", "Library/Caches/Yarn"].sorted())
    }

    // MARK: - Makefile self-sandboxing exclusion (comment-stripping)

    @Test("A Makefile that mentions swift only in a comment does not trigger the self-sandboxing exclusion")
    func makefileCommentMentionDoesNotTriggerExclusion() throws {
        let root = try makefileFixture(contents: """
        # this project also builds a swift companion tool on other platforms
        test:
        \tpytest
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root)
        #expect(!mentions.contains("swift"))
        #expect(!ShellValidationCommandRunner.isSelfSandboxingCommand(root: "make", makefileMentions: mentions))
    }

    @Test("A Makefile that actually invokes swift in a recipe triggers the self-sandboxing exclusion")
    func makefileRecipeMentionTriggersExclusion() throws {
        let root = try makefileFixture(contents: """
        test:
        \tswift test
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root)
        #expect(mentions.contains("swift"))
        #expect(ShellValidationCommandRunner.isSelfSandboxingCommand(root: "make", makefileMentions: mentions))
    }

    @Test("A Makefile that invokes npm in a recipe is detected for the cache-grant dispatch")
    func makefileRecipeMentionIsDetectedForCacheDispatch() throws {
        let root = try makefileFixture(contents: """
        test:
        \tnpm test
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root)
        #expect(mentions == ["npm"])
    }

    @Test("stripMakefileComments removes text after an unescaped # but keeps an escaped \\# literal")
    func stripMakefileCommentsHonorsEscapedHash() {
        let stripped = ShellValidationCommandRunner.stripMakefileComments("""
        test: # runs swift here (comment, should be stripped)
        \techo not-a-comment-\\#swift
        """)
        #expect(!stripped.contains("(comment"))
        #expect(stripped.contains("not-a-comment-\\#swift"))
    }

    @Test("A Makefile that invokes go in a recipe grants the Go cache paths, not npm/yarn/pnpm")
    func makefileGoMentionGrantsGoCachesOnly() throws {
        let root = try makefileFixture(contents: """
        test:
        \tgo test ./...
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root)
        #expect(mentions == ["go"])
        #expect(ShellValidationCommandRunner.toolCacheHomeRelativePaths(forRoot: "make", makefileMentions: mentions).sorted() ==
            ["Library/Caches/go-build", "go/pkg/mod"].sorted())
    }

    @Test("An oversized Makefile is not scanned — treated as mentioning nothing, never wrapped-with-extra-grants")
    func oversizedMakefileIsNotScanned() throws {
        // Deliberately mentions "swift" in a real (non-comment) recipe line —
        // if the size bound didn't short-circuit the scan, this would match.
        let hugeContents = String(repeating: "# padding\n", count: 200_000) + "test:\n\tswift test\n"
        let root = try makefileFixture(contents: hugeContents)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root)
        #expect(mentions.isEmpty)
    }

    @Test("A Makefile that is a symlink to an oversized file is not scanned (fileSize resolves symlinks first)")
    func symlinkedOversizedMakefileIsNotScanned() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-makefile-symlink-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The symlink's OWN size (the length of the path it stores) is tiny —
        // proving the size check must resolve the symlink to see the REAL
        // (huge) target size, not just check the link itself.
        let hugeTarget = root.appendingPathComponent("big.txt")
        try String(repeating: "swift test\n", count: 500_000).write(to: hugeTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Makefile"),
            withDestinationURL: hugeTarget
        )

        let mentions = ShellValidationCommandRunner.makefileMentionedTools(workingDirectory: root.path)
        #expect(mentions.isEmpty)
    }

    private func makefileFixture(contents: String) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-makefile-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        return root.path
    }

    @Test("runTests uses injected command runner")
    func runTestsUsesInjectedCommandRunner() async throws {
        let root = "/tmp/astra-validation-runner-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Validation Runner", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run injected tests", workspace: workspace)
        task.testCommand = "swift test --filter Focused"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "focused pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .passed(let details) = result {
            #expect(details.contains("focused pass"))
        } else {
            Issue.record("Expected injected validation command to pass")
        }
        #expect(await runner.recordedCalls() == [
            StubValidationCommandRunner.Call(
                command: "swift test --filter Focused",
                workingDirectory: root,
                pathContainsShellSuffix: true,
                additionalWritablePaths: AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
            )
        ])
    }

    @Test("runTests rejects shell composition before executing imported task commands")
    func runTestsRejectsShellCompositionBeforeExecution() async throws {
        let root = "/tmp/astra-validation-imported-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported shell composition", workspace: workspace)
        task.testCommand = "true; touch should-not-run"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected unsafe test command to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects background shell operator before execution")
    func runTestsRejectsBackgroundShellOperatorBeforeExecution() async throws {
        let root = "/tmp/astra-validation-background-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Background Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported background shell composition", workspace: workspace)
        task.testCommand = "swift test & touch should-not-run"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected background shell operator to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests allows quoted ampersands in arguments")
    func runTestsAllowsQuotedAmpersandsInArguments() async throws {
        let root = "/tmp/astra-validation-quoted-ampersand-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Quoted Path", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Allow quoted ampersand in validation path", workspace: workspace)
        task.testCommand = "swift test --package-path \"Foo & Bar\""
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "ok", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .passed(let details) = result {
            #expect(details == "ok")
        } else {
            Issue.record("Expected quoted ampersand command to be allowed")
        }
        let calls = await runner.recordedCalls()
        #expect(calls.map(\.command) == ["swift test --package-path \"Foo & Bar\""])
    }

    @Test("runTests rejects zsh process substitution before execution")
    func runTestsRejectsZshProcessSubstitutionBeforeExecution() async throws {
        let root = "/tmp/astra-validation-process-substitution-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Process Substitution Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported zsh process substitution", workspace: workspace)
        task.testCommand = "swift test =(touch should-not-run)"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected zsh process substitution to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects zsh glob execution before execution")
    func runTestsRejectsZshGlobExecutionBeforeExecution() async throws {
        let root = "/tmp/astra-validation-glob-qualifier-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Glob Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported zsh glob execution", workspace: workspace)
        task.testCommand = "swift test *(e:touch${IFS}/tmp/should-not-run:)"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected zsh glob execution to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects double-quoted command substitution before execution")
    func runTestsRejectsDoubleQuotedCommandSubstitutionBeforeExecution() async throws {
        let commands = [
            #"swift test --filter "$(touch should-not-run)""#,
            #"swift test --filter "`touch should-not-run`""#
        ]

        for command in commands {
            let root = "/tmp/astra-validation-command-substitution-\(UUID().uuidString.prefix(8))"
            let workspace = Workspace(name: "Imported Validation Command Substitution Guard", primaryPath: root)
            let task = AgentTask(title: "Validate", goal: "Reject imported command substitution", workspace: workspace)
            task.testCommand = command
            let runner = StubValidationCommandRunner(results: [
                ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
            ])

            let result = await ValidationService.runTests(task: task, commandRunner: runner)

            if case .error(let message) = result {
                #expect(message.contains("not allowed"))
            } else {
                Issue.record("Expected command substitution to be rejected before execution")
            }
            #expect(await runner.recordedCalls().isEmpty)
        }
    }

    @Test("runTests rejects newline command separators before execution")
    func runTestsRejectsNewlineCommandSeparatorsBeforeExecution() async throws {
        let root = "/tmp/astra-validation-newline-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Newline Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported newline command separator", workspace: workspace)
        task.testCommand = "swift test\ntouch should-not-run"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "unsafe pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected newline command separator to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects no-op commands as validation bypasses")
    func runTestsRejectsNoOpCommandsAsValidationBypasses() async throws {
        let root = "/tmp/astra-validation-noop-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation No-op Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported no-op validation", workspace: workspace)
        task.testCommand = "true"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "noop", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected no-op test command to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects swift display-only commands as validation bypasses")
    func runTestsRejectsSwiftDisplayOnlyCommandsAsValidationBypasses() async throws {
        let root = "/tmp/astra-validation-swift-help-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Help Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject imported help-only validation", workspace: workspace)
        task.testCommand = "swift test --help"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "USAGE: swift test", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected swift help command to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
        #expect(!ValidationCommandPolicy.isAllowed("swift build --help"))
        #expect(!ValidationCommandPolicy.isAllowed("swift build --show-bin-path"))
        #expect(!ValidationCommandPolicy.isAllowed("swift test list"))
        #expect(!ValidationCommandPolicy.isAllowed(#"swift test "${UNSET:---help}""#))
        #expect(ValidationCommandPolicy.isAllowed("swift test --filter list"))
    }

    @Test("runTests rejects escaped newline display-only bypasses before execution")
    func runTestsRejectsEscapedNewlineDisplayOnlyBypassesBeforeExecution() async throws {
        let root = "/tmp/astra-validation-escaped-newline-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Escaped Newline Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject escaped newline display-only validation", workspace: workspace)
        task.testCommand = "swift test \\\n--help"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "USAGE: swift test", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected escaped newline display-only command to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects Swift graph-only build commands before execution")
    func runTestsRejectsSwiftGraphOnlyBuildCommandsBeforeExecution() async throws {
        let root = "/tmp/astra-validation-swift-graph-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Imported Validation Swift Graph Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject Swift graph-only build validation", workspace: workspace)
        task.testCommand = "swift build --print-manifest-job-graph"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "{ \"commands\": [] }", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected Swift graph-only build command to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("runTests rejects file assertions as test commands")
    func runTestsRejectsFileAssertionsAsTestCommands() async throws {
        let commands = [
            "test -f Package.swift",
            "[ -f Package.swift ]"
        ]

        for command in commands {
            let root = "/tmp/astra-validation-file-assertion-\(UUID().uuidString.prefix(8))"
            let workspace = Workspace(name: "Imported Validation File Assertion Guard", primaryPath: root)
            let task = AgentTask(title: "Validate", goal: "Reject file assertion as run-tests validation", workspace: workspace)
            task.testCommand = command
            let runner = StubValidationCommandRunner(results: [
                ValidationCommandResult(exitCode: 0, stdout: "", stderr: "")
            ])

            let result = await ValidationService.runTests(task: task, commandRunner: runner)

            if case .error(let message) = result {
                #expect(message.contains("not allowed"))
            } else {
                Issue.record("Expected file assertion command to be rejected before execution")
            }
            #expect(await runner.recordedCalls().isEmpty)
        }
    }

    @Test("runTests rejects Swift package paths outside the task workspace")
    func runTestsRejectsSwiftPackagePathsOutsideTaskWorkspace() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let workspace = Workspace(name: "Imported Validation Path Guard", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Reject test package path outside workspace", workspace: workspace)
        task.testCommand = "swift test --package-path \(outsideRoot)"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "outside pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .error(let message) = result {
            #expect(message.contains("not allowed"))
        } else {
            Issue.record("Expected package path outside the task workspace to be rejected before execution")
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("validation command policy allows help and version as argument values")
    func validationCommandPolicyAllowsHelpAndVersionAsArgumentValues() {
        #expect(ValidationCommandPolicy.isAllowed("swift test --filter help"))
        #expect(ValidationCommandPolicy.isAllowed("swift test --filter version"))
        #expect(ValidationCommandPolicy.isAllowed("pytest -k help"))
        #expect(ValidationCommandPolicy.isAllowed("pytest -k version"))
    }

    @Test("validation contract command assertions use injected runner")
    func validationContractCommandAssertionsUseInjectedRunner() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Runner", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run command through injected runner", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 7, stdout: "stdout detail", stderr: "stderr detail")
        ])
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-runner",
                    description: "Command exits zero",
                    method: .command,
                    command: "swift test --filter Focused"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            commandRunner: runner
        )

        #expect(result.didRun)
        #expect(result.outcome == .failed)
        #expect(!result.canComplete)
        #expect(await runner.recordedCalls() == [
            StubValidationCommandRunner.Call(
                command: "swift test --filter Focused",
                workingDirectory: root,
                pathContainsShellSuffix: true,
                additionalWritablePaths: AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
            )
        ])
        let assertionEvent = try #require(task.events.first { $0.type == TaskValidationEventTypes.assertionFailed })
        let payload = try JSONDecoder().decode(
            TaskValidationAssertionEventPayload.self,
            from: Data(assertionEvent.payload.utf8)
        )
        #expect(payload.exitCode == 7)
        #expect(payload.evidence == "stdout detail\nstderr detail")
        #expect(payload.reason == "command_failed")
        let diagnostic = ValidationAssertionExecutionResult(payload: payload)
        #expect(diagnostic.outcome == .failed)
        #expect(diagnostic.status == .failed)
        #expect(!diagnostic.didPass)
        #expect(diagnostic.auditFields["result"] == "failed")
        #expect(diagnostic.auditFields["failure_reason"] == "command_failed")
        #expect(diagnostic.auditFields["exit_code"] == "7")
    }

    @Test("validation contract command pass records assertion and contract events")
    func validationContractCommandPasses() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeMinimalSwiftPackage(at: root)
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-pass",
                    description: "Command exits zero",
                    method: .command,
                    command: "swift build --package-path \(root)"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.outcome == .passed)
        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionStarted })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("validation contract command failure blocks completion")
    func validationContractCommandFailureBlocksCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Failure", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a failing proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a failing proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-fails",
                    description: "Command exits non-zero",
                    method: .command,
                    command: "swift build --package-path \(root)/missing-package"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.outcome == .failed)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["command-fails"])
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
        let contractEvent = try #require(task.events.first { $0.type == TaskValidationEventTypes.contractFailed })
        let contractPayload = try JSONDecoder().decode(
            TaskValidationContractEventPayload.self,
            from: Data(contractEvent.payload.utf8)
        )
        #expect(contractPayload.outcome == .failed)
        let correctiveEvent = try #require(task.events.first { $0.type == TaskCorrectiveEventTypes.stepCreated })
        #expect(correctiveEvent.payload.contains("command-fails"))
        #expect(correctiveEvent.payload.contains("Fix the work until this command exits 0"))
    }

    @Test("validation contract command allowlist blocks shell composition before execution")
    func validationContractCommandAllowlistBlocksShellCompositionBeforeExecution() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject composed validation commands", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let markerPath = (root as NSString).appendingPathComponent("should-not-exist.txt")
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject unsafe proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "unsafe-command",
                    description: "Composed shell command is rejected",
                    method: .command,
                    command: "true; touch \(markerPath)"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
        #expect(task.events.contains {
            $0.type == TaskCorrectiveEventTypes.stepCreated &&
                $0.payload.contains("Replace this command assertion with structured artifact") &&
                $0.payload.contains("text_contains")
        })
    }

    @Test("validation contract command allowlist blocks repo scripts before execution")
    func validationContractCommandAllowlistBlocksRepoScriptsBeforeExecution() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Script Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject repo script validation commands", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let scriptDirectory = (root as NSString).appendingPathComponent("script")
        try FileManager.default.createDirectory(atPath: scriptDirectory, withIntermediateDirectories: true)
        let markerPath = (root as NSString).appendingPathComponent("script-ran.txt")
        let scriptPath = (scriptDirectory as NSString).appendingPathComponent("validation-danger.sh")
        try """
        #!/bin/sh
        touch "\(markerPath)"
        """.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject repo script command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "script-command",
                    description: "Repo scripts are not trusted validation commands",
                    method: .command,
                    command: "script/validation-danger.sh"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
    }

    @Test("validation command policy rejects package manager test script name smuggling")
    func validationCommandPolicyRejectsPackageManagerTestScriptNameSmuggling() {
        #expect(ValidationCommandPolicy.isAllowed("npm run test"))
        #expect(ValidationCommandPolicy.isAllowed("npm run test -- --watch=false"))
        #expect(ValidationCommandPolicy.isAllowed("npm test -- --watch=false"))
        #expect(!ValidationCommandPolicy.isAllowed("npm test --help"))
        #expect(!ValidationCommandPolicy.isAllowed("npm run test --if-present"))
        #expect(!ValidationCommandPolicy.isAllowed("npm test --script-shell=/bin/true"))
        #expect(!ValidationCommandPolicy.isAllowed("npm run test:evil"))
        #expect(ValidationCommandPolicy.isAllowed("yarn run test"))
        #expect(ValidationCommandPolicy.isAllowed("yarn run test --ci"))
        #expect(!ValidationCommandPolicy.isAllowed("yarn test --help"))
        #expect(!ValidationCommandPolicy.isAllowed("yarn run test --version"))
        #expect(!ValidationCommandPolicy.isAllowed("yarn run test:evil"))
        #expect(ValidationCommandPolicy.isAllowed("pnpm run test"))
        #expect(ValidationCommandPolicy.isAllowed("pnpm run test -- --runInBand"))
        #expect(!ValidationCommandPolicy.isAllowed("pnpm test --help"))
        #expect(!ValidationCommandPolicy.isAllowed("pnpm run test --markers"))
        #expect(!ValidationCommandPolicy.isAllowed("pnpm run test:evil"))
    }

    @Test("validation command policy matches xcodebuild actions by token")
    func validationCommandPolicyMatchesXcodebuildActionsByToken() {
        let workspaceRoot = "/tmp/astra-validation-xcode-root-\(UUID().uuidString)"
        let outsideRoot = "/tmp/astra-validation-xcode-outside-\(UUID().uuidString)"
        #expect(ValidationCommandPolicy.isAllowed("xcodebuild -project App.xcodeproj build"))
        #expect(ValidationCommandPolicy.isAllowed("xcodebuild -scheme App test"))
        #expect(ValidationCommandPolicy.isAllowed("xcodebuild build-for-testing -workspace App.xcworkspace -scheme App"))
        #expect(ValidationCommandPolicy.isAllowed("xcodebuild test-without-building -workspace App.xcworkspace -scheme App"))
        #expect(ValidationCommandPolicy.isAssertionCommandAllowed(
            "xcodebuild build -project \(workspaceRoot)/App.xcodeproj",
            workspacePath: workspaceRoot
        ))
        #expect(!ValidationCommandPolicy.isAssertionCommandAllowed(
            "xcodebuild build -project \(outsideRoot)/App.xcodeproj",
            workspacePath: workspaceRoot
        ))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild archive -project test.xcodeproj"))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild test archive -project test.xcodeproj"))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild -list -project build.xcodeproj"))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild -showBuildSettings build"))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild -version test"))
        #expect(!ValidationCommandPolicy.isAllowed("xcodebuild -scheme test"))
    }

    @Test("validation command policy scopes absolute paths inside flag assignments")
    func validationCommandPolicyScopesAbsolutePathsInsideFlagAssignments() {
        let workspaceRoot = "/tmp/astra-validation-flags-\(UUID().uuidString)"
        #expect(ValidationCommandPolicy.isAssertionCommandAllowed(
            "pytest --junitxml=\(workspaceRoot)/reports/results.xml",
            workspacePath: workspaceRoot
        ))
        #expect(!ValidationCommandPolicy.isAssertionCommandAllowed(
            "pytest --junitxml=/tmp/outside-results.xml",
            workspacePath: workspaceRoot
        ))
        #expect(!ValidationCommandPolicy.isAssertionCommandAllowed(
            "pytest report=/tmp/outside-results.xml",
            workspacePath: workspaceRoot
        ))
    }

    @Test("validation command policy keeps make to the single test target")
    func validationCommandPolicyKeepsMakeToSingleTestTarget() {
        #expect(ValidationCommandPolicy.isAllowed("make test"))
        #expect(ValidationCommandPolicy.isAllowed("make test -j2"))
        #expect(ValidationCommandPolicy.isAllowed("make test --jobs=2 --keep-going"))
        #expect(ValidationCommandPolicy.isAllowed("make test -j 2"))
        #expect(ValidationCommandPolicy.isAllowed("make test --jobs 2"))
        #expect(!ValidationCommandPolicy.isAllowed("make test -j"))
        #expect(!ValidationCommandPolicy.isAllowed("make test --jobs"))
        #expect(!ValidationCommandPolicy.isAllowed("make test clean"))
        #expect(!ValidationCommandPolicy.isAllowed("make build"))
        #expect(!ValidationCommandPolicy.isAllowed("make test CI=1"))
        #expect(!ValidationCommandPolicy.isAllowed("make test SHELL=/bin/true"))
        #expect(!ValidationCommandPolicy.isAllowed("make test '--eval=$(shell touch should-not-run)'"))
        #expect(!ValidationCommandPolicy.isAllowed("make test '-E$(shell touch should-not-run)'"))
        #expect(!ValidationCommandPolicy.isAllowed("make test 'CI=$(shell touch should-not-run)'"))
        #expect(!ValidationCommandPolicy.isAllowed("make test 'CI=${shell touch should-not-run}'"))
        #expect(!ValidationCommandPolicy.isAllowed("make test --file=Injected.mk"))
    }

    @Test("validation command policy preserves file test assertions without allowing no-ops")
    func validationCommandPolicyPreservesFileTestAssertionsWithoutAllowingNoOps() {
        let workspaceRoot = "/tmp/astra-validation-file-test-root-\(UUID().uuidString)"
        #expect(ValidationCommandPolicy.isAllowed("test -f proof.txt"))
        #expect(ValidationCommandPolicy.isAllowed("test -d artifacts/report"))
        #expect(ValidationCommandPolicy.isAllowed("[ -f proof.txt ]"))
        #expect(!ValidationCommandPolicy.isRunTestsCommandAllowed("test -f proof.txt", workspacePath: workspaceRoot))
        #expect(ValidationCommandPolicy.isAssertionCommandAllowed("test -f proof.txt", workspacePath: workspaceRoot))
        #expect(!ValidationCommandPolicy.isAllowed("test -d /"))
        #expect(!ValidationCommandPolicy.isAllowed("[ -e / ]"))
        #expect(!ValidationCommandPolicy.isAllowed("test -f ../outside"))
        #expect(!ValidationCommandPolicy.isAllowed("test -f =zsh"))
        #expect(!ValidationCommandPolicy.isAllowed("test"))
        #expect(!ValidationCommandPolicy.isAllowed("[ ]"))
        #expect(!ValidationCommandPolicy.isAllowed("test -f proof.txt; touch should-not-run"))
    }

    @Test("validation command policy rejects python pytest display-only commands")
    func validationCommandPolicyRejectsPythonPytestDisplayOnlyCommands() {
        #expect(!ValidationCommandPolicy.isAllowed("python -m pytest --help"))
        #expect(!ValidationCommandPolicy.isAllowed("python3 -m pytest --version"))
        #expect(!ValidationCommandPolicy.isAllowed("python3 -m pytest --collect-only"))
        #expect(!ValidationCommandPolicy.isAllowed("pytest --collect-only"))
        #expect(!ValidationCommandPolicy.isAllowed("pytest --setup-plan"))
        #expect(!ValidationCommandPolicy.isAllowed("pytest --fixtures"))
        #expect(!ValidationCommandPolicy.isAllowed("pytest --markers"))
        #expect(ValidationCommandPolicy.isAllowed("python -m pytest -k help"))
    }

    @Test("validation contract command allowlist blocks python before pytest module")
    func validationContractCommandAllowlistBlocksPythonBeforePytestModule() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Python Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject arbitrary Python before pytest", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let markerPath = (root as NSString).appendingPathComponent("python-ran.txt")
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject unsafe Python command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "python-command",
                    description: "Python must start with -m pytest",
                    method: .command,
                    command: #"python -c 'open("\#(markerPath)","w").write("x")' -m pytest"#
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
    }

    @Test("validation contract artifact check resolves task output folder paths")
    func validationContractArtifactCheckUsesTaskFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Validation", primaryPath: root)
        let task = AgentTask(title: "Validate artifact", goal: "Require an output artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "report".write(
            toFile: (taskFolder as NSString).appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require an output artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-exists",
                    description: "Report exists",
                    method: .artifact,
                    path: "report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("report.md") })
    }

    @Test("validation contract artifact rejects directories unless expected")
    func validationContractArtifactRejectsDirectoriesUnlessExpected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Directory", primaryPath: root)
        let task = AgentTask(title: "Validate artifact directory", goal: "Reject directory as file artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let directoryPath = (taskFolder as NSString).appendingPathComponent("report")
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject directory artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-file",
                    description: "Report file exists",
                    method: .artifact,
                    path: "report"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["report-file"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("artifact_directory_not_allowed")
        })
    }

    @Test("validation contract artifact allows explicit directory type")
    func validationContractArtifactAllowsExplicitDirectoryType() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Directory Allowed", primaryPath: root)
        let task = AgentTask(title: "Validate artifact directory", goal: "Allow directory artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let directoryPath = (taskFolder as NSString).appendingPathComponent("report")
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Allow directory artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-directory",
                    description: "Report directory exists",
                    method: .artifact,
                    path: "report",
                    expectedArtifactType: "directory"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("report-directory")
        })
    }

    @Test("validation contract text contains resolves task output files")
    func validationContractTextContainsUsesTaskFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contains", primaryPath: root)
        let task = AgentTask(title: "Validate text", goal: "Require generated page text", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Med13 Foundation</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Text proof",
            goal: "Require generated page text",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-exists",
                    description: "Index page exists",
                    method: .artifact,
                    path: "index.html"
                ),
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13 Foundation"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13") &&
                $0.payload.contains("text_contains")
        })
    }

    @Test("validation contract text contains failure blocks completion")
    func validationContractTextContainsFailureBlocksCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Missing", primaryPath: root)
        let task = AgentTask(title: "Validate text", goal: "Require missing text", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Other Foundation</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Text proof",
            goal: "Require missing text",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13 Foundation"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("expected_text_missing")
        })
        #expect(task.events.contains {
            $0.type == TaskCorrectiveEventTypes.stepCreated &&
                $0.payload.contains("index-med13") &&
                $0.payload.contains("index.html") &&
                $0.payload.contains("expected text")
        })
    }

    @Test("validation contract text contains requires evidence query")
    func validationContractTextContainsRequiresEvidenceQuery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contract", primaryPath: root)
        let task = AgentTask(title: "Validate text contract", goal: "Reject malformed text assertion", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Index page names Med13</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Malformed text proof",
            goal: "Reject text_contains without evidence query",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("missing_expected_text")
        })
        #expect(!task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13")
        })
    }

    @Test("validation contract text contains rejects unknown file size before reading")
    func validationContractTextContainsRejectsUnknownFileSize() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contract", primaryPath: root)
        let task = AgentTask(title: "Validate text contract", goal: "Reject unknown-size text assertion", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Index page names Med13</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Unknown size text proof",
            goal: "Reject text_contains when file size cannot be determined",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13"
                )
            ])
        )

        let originalProbe = ValidationService.textContainsFileSizeProbe
        ValidationService.textContainsFileSizeProbe = { _ in nil }
        defer { ValidationService.textContainsFileSizeProbe = originalProbe }

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("artifact_size_unknown")
        })
        #expect(!task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13")
        })
    }

    @Test("validation contract rejects artifact paths outside task scope")
    func validationContractRejectsArtifactPathsOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Scope", primaryPath: root)
        let task = AgentTask(title: "Validate artifact scope", goal: "Reject outside artifacts", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing-report.md")
        try "outside".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject outside artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "absolute-artifact",
                    description: "Absolute paths are not trusted evidence",
                    method: .artifact,
                    path: outsidePath
                ),
                TaskValidationAssertion(
                    id: "parent-artifact",
                    description: "Parent traversal is not trusted evidence",
                    method: .artifact,
                    path: "../existing-report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs.contains("absolute-artifact"))
        #expect(result.failedRequiredAssertionIDs.contains("parent-artifact"))
        let scopedFailures = task.events.filter {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        }
        #expect(scopedFailures.count == 2)
    }

    @Test("validation contract rejects artifact symlinks outside task scope")
    func validationContractRejectsArtifactSymlinksOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Symlink Scope", primaryPath: root)
        let task = AgentTask(title: "Validate artifact symlink scope", goal: "Reject symlinked outside artifacts", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing-report.md")
        try "outside".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let linkPath = (taskFolder as NSString).appendingPathComponent("linked-report.md")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outsidePath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject symlinked outside artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "symlink-artifact",
                    description: "Symlink targets outside scope are not trusted evidence",
                    method: .artifact,
                    path: "linked-report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["symlink-artifact"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("validation contract rejects browser behavior paths outside task scope")
    func validationContractRejectsBrowserBehaviorPathsOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Scope", primaryPath: root)
        let task = AgentTask(title: "Validate browser scope", goal: "Reject outside HTML", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing.html")
        try "<html><body>ready</body></html>".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject outside browser artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "absolute-browser",
                    description: "ready",
                    method: .browserBehavior,
                    path: outsidePath
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["absolute-browser"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
        #expect(task.events.contains {
            $0.type == TaskValidationBehaviorEventTypes.failed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("validation contract rejects browser behavior symlinks outside task scope")
    func validationContractRejectsBrowserBehaviorSymlinksOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Symlink Scope", primaryPath: root)
        let task = AgentTask(title: "Validate browser symlink scope", goal: "Reject symlinked outside HTML", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing.html")
        try "<html><body>ready</body></html>".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let linkPath = (taskFolder as NSString).appendingPathComponent("linked.html")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outsidePath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject symlinked outside browser artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "symlink-browser",
                    description: "ready",
                    method: .browserBehavior,
                    path: "linked.html"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["symlink-browser"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
        #expect(task.events.contains {
            $0.type == TaskValidationBehaviorEventTypes.failed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("failed validation creates one corrective item with auditable lifecycle")
    func failedValidationCreatesOneCorrectiveItemWithAuditableLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Corrective", primaryPath: root)
        let task = AgentTask(title: "Corrective validation", goal: "Create a failing correction", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require corrective work",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "must-pass",
                    description: "Command passes",
                    method: .command,
                    command: "swift build --package-path \(root)/missing-package"
                )
            ])
        )

        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)
        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        let proposedEvents = task.events.filter { $0.type == TaskCorrectiveEventTypes.stepCreated }
        #expect(proposedEvents.count == 1)
        let record = try #require(TaskCorrectiveWorkQueries.openCorrectiveSteps(for: task).first)
        let correctiveStepID = TaskCorrectiveWorkQueries.normalizedCorrectiveStepID(record.payload)

        var state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let corrective = try #require(state.correctiveWork?.first)
        #expect(corrective.correctiveStepID == correctiveStepID)
        #expect(corrective.status == "proposed")
        #expect(corrective.failedAssertionID == "must-pass")
        #expect(state.nextLikelyAction?.contains("failed assertion must-pass") == true)
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Corrective work:"))
        #expect(prompt.contains("must-pass"))

        let approved = try #require(TaskCorrectiveWorkService.approveStep(
            task: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(approved.status == "approved")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepApproved })

        let child = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(child.goal.contains("must-pass"))
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.taskCreated && $0.payload.contains(child.id.uuidString) })

        let duplicateChild = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(duplicateChild.id == child.id)
        #expect(workspace.tasks.filter { $0.constraints.contains("Failed assertion ID: must-pass") }.count == 1)
        #expect(task.events.filter { $0.type == TaskCorrectiveEventTypes.taskCreated }.count == 1)

        let dismissed = try #require(TaskCorrectiveWorkService.dismissStep(
            task: task,
            correctiveStepID: correctiveStepID,
            reason: "Handled in a different task",
            modelContext: context
        ))
        #expect(dismissed.status == "dismissed")
        #expect(dismissed.dismissedReason == "Handled in a different task")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepDismissed })

        state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let finalCorrective = try #require(state.correctiveWork?.first)
        #expect(finalCorrective.status == "dismissed")
        #expect(finalCorrective.correctiveTaskID == child.id.uuidString)
        let markdown = try String(
            contentsOfFile: (TaskWorkspaceAccess(task: task).taskFolder as NSString)
                .appendingPathComponent(TaskContextStateManager.markdownFileName),
            encoding: .utf8
        )
        #expect(markdown.contains("## Corrective Work"))
        #expect(markdown.contains("Handled in a different task"))
    }

    @Test("browser behavior assertion passes with deterministic evidence")
    func browserBehaviorAssertionPassesWithDeterministicEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try """
        <html><head><title>Demo</title></head><body><h1>Checkout Ready</h1></body></html>
        """.write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-visible",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.started })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.evidenceAttached })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.passed })
        let assertionEvent = try #require(task.events.first {
            $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("browser-visible")
        })
        #expect(assertionEvent.payload.contains("validation-evidence"))
        let state = try #require(TaskContextStateManager.load(taskFolder: taskFolder))
        let assertion = try #require(state.validationContract?.assertions.first { $0.id == "browser-visible" })
        #expect(assertion.sourcePointers.contains { $0.kind == "validation_evidence" && $0.path?.contains("browser-visible-behavior.json") == true })
    }

    @Test("browser behavior assertion failure blocks required contract")
    func browserBehaviorAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior Failure", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Still Loading</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-missing",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["browser-missing"])
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.failed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("browser-missing") })
    }

    @Test("verifier assertion pass satisfies required contract")
    func verifierAssertionPassSatisfiesRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "PASS\nReviewed assertion verifier-pass.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Pass", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        run.output = "Worker says the change is complete."
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-pass",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.started })
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"pass\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("verifier-pass") })
    }

    @Test("verifier assertion failure blocks required contract")
    func verifierAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "FAIL\nMissing expected behavior evidence.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Fail", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-fail",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["verifier-fail"])
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"fail\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("verifier_failed_assertion") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("verifier-fail") })
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-validation-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeMinimalSwiftPackage(at root: String) throws {
        let package = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "ValidationFixture",
            targets: [
                .executableTarget(name: "ValidationFixture")
            ]
        )
        """
        let sources = URL(fileURLWithPath: root)
            .appendingPathComponent("Sources/ValidationFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try package.write(
            to: URL(fileURLWithPath: root).appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try #"@main struct ValidationFixture { static func main() {} }"#.write(
            to: sources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func fakeCopilotUtility(in root: String, output: String) throws -> URL {
        let fakeCopilot = URL(fileURLWithPath: root).appendingPathComponent("copilot")
        let escaped = output
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(escaped)"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)
        return fakeCopilot
    }
}
