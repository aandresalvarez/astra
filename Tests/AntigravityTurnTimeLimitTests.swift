import Foundation
import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels

/// Prod task 7900335C: 12 of its 57 Antigravity turns ended at exactly ten
/// minutes, each recorded as completed, because ASTRA handed agy its idle
/// timeout as `--print-timeout` — a limit on the whole turn. Every ASTRA
/// watchdog kill on that task came after an agy self-update had silently
/// dropped the launch to plain text.
@Suite("Antigravity turn time limit")
struct AntigravityTurnTimeLimitTests {
    private static let printTimeoutStderr =
        "[agy] print timeout after 10m0s with turn in progress; returning partial output"

    private static func plan(
        structuredOutputAllowed: Bool = true,
        executablePath: String = "/bin/agy",
        defaults: UserDefaults
    ) -> AntigravityCLICommandPlan {
        AntigravityCLIRuntime.buildCommand(
            executablePath: executablePath,
            prompt: "hello",
            workspacePath: "/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.antigravityLaunchPermissionArguments(policy: .restricted),
            structuredOutputAllowed: structuredOutputAllowed,
            defaults: defaults
        )
    }

    private static func printTimeoutValue(_ plan: AntigravityCLICommandPlan) -> String? {
        guard let flag = plan.arguments.firstIndex(of: "--print-timeout"),
              plan.arguments.indices.contains(flag + 1) else { return nil }
        return plan.arguments[flag + 1]
    }

    @Test("agy is told to wait for the turn, never handed a turn limit")
    func printTimeoutWaitsForTheTurn() {
        let defaults = InMemoryDefaults()
        AntigravityCLIRuntime.cacheStructuredOutputSupport(true, executablePath: "/bin/agy", defaults: defaults)

        // Task runs (stream-json) and utility runs (plain text) alike: ASTRA's
        // own watchdogs bound the run, so agy gets `0s`, its "until the turn
        // completes", and nothing derived from a timeout setting.
        #expect(Self.printTimeoutValue(Self.plan(defaults: defaults)) == "0s")
        #expect(Self.printTimeoutValue(Self.plan(structuredOutputAllowed: false, defaults: defaults)) == "0s")
        #expect(Self.plan(defaults: defaults).arguments.filter { $0 == "--print-timeout" }.count == 1)
    }

    @Test("The adapter does not turn the worker's idle timeout into agy's turn limit")
    @MainActor
    func adapterIgnoresTheIdleTimeout() {
        let workspace = Workspace(name: "Turn limit", primaryPath: "/tmp/astra-turn-limit")
        let task = AgentTask(
            title: "Long turn",
            goal: "Work for more than ten minutes",
            workspace: workspace,
            model: "default",
            runtime: .antigravityCLI
        )
        let plan = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/agy-not-present",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                // The shipped Settings › Execution › Timeout default.
                timeoutSeconds: 600
            ))

        guard let flag = plan.arguments.firstIndex(of: "--print-timeout") else {
            Issue.record("agy must still be told how long to wait")
            return
        }
        #expect(plan.arguments[flag + 1] == "0s")
        #expect(!plan.arguments.contains("600s"))
    }

    @Test("agy's print-timeout marker settles the turn as cut short, terminally")
    func printTimeoutMarkerIsAStop() throws {
        let stop = try #require(AntigravityCLIRuntime.printTimeoutStop(stderr: Self.printTimeoutStderr))

        #expect(stop.reason == TaskRunStopReason.providerTurnTimeLimitReached.rawValue)
        #expect(TaskRunStopReason(rawValue: stop.reason) != nil)
        // Not approvable: a review the user can never satisfy must not park the
        // task in pendingUser.
        #expect(AgentRuntimeWorker.isTerminalRuntimeStop(stop.reason))
        #expect(stop.message.contains("after 10m0s"))
        #expect(stop.message.contains("did not count the turn as complete"))
        #expect(!stop.message.contains("background task"))
    }

    @Test("Background tasks agy killed on exit are named in the stop message")
    func printTimeoutNamesTerminatedBackgroundTasks() throws {
        let stderr = """
        root agent idle; waiting up to 10m0s for 2 background task(s)
        \(Self.printTimeoutStderr)
        terminating 2 background task(s) on exit
        """

        let stop = try #require(AntigravityCLIRuntime.printTimeoutStop(stderr: stderr))

        #expect(stop.message.contains("terminated 2 background task(s)"))
    }

    @Test("Other stderr is not mistaken for a cut-short turn", arguments: [
        "",
        "root agent idle; waiting up to 10m0s for 1 background task(s)",
        "terminating 1 background task(s) on exit",
        "Fetching available models...",
        "error: interrupted"
    ])
    func unrelatedStderrIsNotAStop(stderr: String) {
        #expect(AntigravityCLIRuntime.printTimeoutStop(stderr: stderr) == nil)
    }

    @Test("Only the Antigravity adapter reads agy's marker")
    func onlyAntigravityReadsTheMarker() {
        #expect(AgentRuntimeAdapterRegistry.processEventParser(for: .antigravityCLI)
            .providerSelfStop(stderr: Self.printTimeoutStderr)?.reason
            == TaskRunStopReason.providerTurnTimeLimitReached.rawValue)
        let others: [AgentRuntimeID] = [.claudeCode, .copilotCLI, .codexCLI, .cursorCLI, .openCodeCLI]
        for runtime in others where AgentRuntimeAdapterRegistry.hasAdapter(for: runtime) {
            #expect(AgentRuntimeAdapterRegistry.processEventParser(for: runtime)
                .providerSelfStop(stderr: Self.printTimeoutStderr) == nil, "\(runtime.rawValue)")
        }
    }

    /// A fake `agy` that answers `--help` with the stream-json flag and counts
    /// how often it was asked.
    private struct FakeAgy {
        let root: URL
        let executable: URL
        let helpCount: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-agy-reprobe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appendingPathComponent("agy")
            helpCount = root.appendingPathComponent("help-count")
            try write(version: "1.2.2")
        }

        /// Rewrites the binary in place, as `agy update` does.
        func write(version: String) throws {
            let script = """
            #!/bin/sh
            # agy \(version)
            if [ "$1" = "--help" ]; then
              printf 'x' >> '\(helpCount.path)'
              printf '%s\\n' '  --output-format  Output format for print mode (text, json, stream-json)'
              exit 0
            fi
            exit 0
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        var helpInvocations: Int {
            (try? Data(contentsOf: helpCount).count) ?? 0
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("A launch after agy updated itself asks again instead of running blind")
    @MainActor
    func launchReprobesAfterSelfUpdate() async throws {
        let agy = try FakeAgy()
        defer { agy.cleanup() }
        let defaults = InMemoryDefaults()

        // The verdict cached before the update, for the old binary.
        AntigravityCLIRuntime.cacheStructuredOutputSupport(true, executablePath: agy.executable.path, defaults: defaults)
        #expect(Self.plan(executablePath: agy.executable.path, defaults: defaults).parsesJSONLines)

        try agy.write(version: "1.2.3-with-a-longer-version-string")
        // The update misses the stamp, and the command alone cannot ask.
        #expect(AntigravityCLIRuntime.cachedStructuredOutputVerdict(
            executablePath: agy.executable.path, defaults: defaults
        ) == nil)
        #expect(!Self.plan(executablePath: agy.executable.path, defaults: defaults).parsesJSONLines)

        let supported = await AntigravityCLIRuntime.warmStructuredOutputSupportBeforeLaunch(
            executablePath: agy.executable.path,
            providerHomeDirectory: "",
            defaults: defaults
        )

        #expect(supported)
        #expect(agy.helpInvocations == 1)
        let relaunched = Self.plan(executablePath: agy.executable.path, defaults: defaults)
        #expect(relaunched.parsesJSONLines)
        #expect(relaunched.arguments.contains("stream-json"))

        // Cached for the new binary: the next launch does not shell out.
        _ = await AntigravityCLIRuntime.warmStructuredOutputSupportBeforeLaunch(
            executablePath: agy.executable.path,
            providerHomeDirectory: "",
            defaults: defaults
        )
        #expect(agy.helpInvocations == 1)
    }

    @Test("A probe that cannot answer caches nothing, so the next launch asks again")
    @MainActor
    func failedReprobeIsNotCached() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-agy-reprobe-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agy")
        try "#!/bin/sh\nexit 3\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let defaults = InMemoryDefaults()

        let supported = await AntigravityCLIRuntime.warmStructuredOutputSupportBeforeLaunch(
            executablePath: executable.path,
            providerHomeDirectory: "",
            defaults: defaults
        )

        #expect(!supported)
        #expect(AntigravityCLIRuntime.cachedStructuredOutputVerdict(
            executablePath: executable.path, defaults: defaults
        ) == nil)
    }
}
