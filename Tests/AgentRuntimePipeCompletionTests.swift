import Foundation
import Testing
import ASTRAModels
import ASTRACore
@testable import ASTRA

@Suite("Agent runtime pipe completion", .serialized)
@MainActor
struct AgentRuntimePipeCompletionTests {
    private enum Stop: Sendable, Equatable { case natural, timeout, cancellation, earlyResult }

    @Test("A reaped provider finishes despite escaped pipe holders", arguments: [false, true])
    func naturalExit(worker: Bool) async throws { try await exercise(.natural, worker: worker) }

    @Test("Timeout does not wait for an escaped descendant's EOF", arguments: [false, true])
    func timeout(worker: Bool) async throws { try await exercise(.timeout, worker: worker) }

    @Test("Cancellation does not wait for an escaped descendant's EOF", arguments: [false, true])
    func cancellation(worker: Bool) async throws { try await exercise(.cancellation, worker: worker) }

    @Test("A utility terminal result still drains diagnostics and reaps the provider")
    func earlyResult() async throws { try await exercise(.earlyResult, worker: false) }

    @Test("Worker reports raw stdout bytes including newlines and the final partial line")
    func rawByteAccounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-stream-bytes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = String(repeating: "😀x", count: 10_000) + "\nlast — fin"
        let input = root.appendingPathComponent("stdout")
        try payload.write(to: input, atomically: true, encoding: .utf8)
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode, executablePath: "/bin/cat", arguments: [input.path],
            currentDirectory: root.path, environment: [:], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: false
        )
        let task = AgentTask(title: "Byte accounting", goal: "Synthetic")
        let runner = AgentRuntimeProcessRunner { _ in ExecutionSandboxSettings(enforcement: .off) }
        let result = await runner.runRuntimeProcess(
            adapter: PipeFixtureAdapter(plan: plan, unknownEvents: true), prompt: "Synthetic", task: task,
            workspacePath: root.path, executablePath: "/bin/cat", homeDirectory: root.path,
            permissionPolicy: .restricted, timeoutSeconds: 20, onLine: { _, _ in }
        )
        #expect(result.exitCode == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        var audit: String?
        repeat {
            audit = AppLogger.entries.last { $0.taskID == task.id && $0.message.hasPrefix("runtime.unknown_event") }?.message
            if audit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let message = try #require(audit)
        #expect(message.contains("stream_bytes=\(payload.utf8.count)"))
        #expect(message.contains("unknown_events=2"))
    }

    private func exercise(_ stop: Stop, worker: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-pipe-holder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hold = root.appendingPathComponent("hold")
        let ready = root.appendingPathComponent("ready")
        try Data().write(to: hold)
        // Old readToEOF must fail finitely, with no helper left behind.
        let breaker = Task.detached {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            try? FileManager.default.removeItem(at: hold)
        }
        defer { breaker.cancel() }
        // Non-interactive shell job control races the runner's process-group
        // setup and can add setpgid errors to stderr. Fork into a fresh session
        // explicitly, so the escaped pipe holder has no shell bookkeeping.
        let script = """
        import os, pathlib, signal, sys, time
        hold, ready = map(pathlib.Path, sys.argv[1:])
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            ready.write_text('ready')
            while hold.exists():
                time.sleep(0.05)
            os._exit(0)
        while not ready.exists():
            time.sleep(0.01)
        os.write(2, 'last stderr — fin'.encode('utf-8'))
        os.write(1, 'last stdout — fin\(stop == .earlyResult ? "\\n" : "")'.encode('utf-8'))
        \(stop == .natural ? "os._exit(0)" : "os.waitpid(child, 0)")
        """
        let runner = AgentRuntimeProcessRunner { _ in ExecutionSandboxSettings(enforcement: .off) }
        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode, executablePath: "/usr/bin/python3",
            arguments: ["-c", script, hold.path, ready.path],
            currentDirectory: root.path, environment: RuntimeProcessEnvironment.enriched(),
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false
        )
        let diagnostics = AgentLockedBuffer()
        let operation = Task<AgentUtilityRunResult, Never> { @MainActor in
            await runFixture(plan: plan, root: root, runner: runner, stop: stop, worker: worker, diagnostics: diagnostics)
        }
        defer { operation.cancel(); runner.cancel() }
        if stop == .cancellation {
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            operation.cancel()
            runner.cancel()
        }
        let result = await operation.value
        #expect(FileManager.default.fileExists(atPath: ready.path), "Exercise a descendant that actually started")
        #expect(FileManager.default.fileExists(atPath: hold.path), "Completion waited for the hang breaker to release the pipe holder")
        switch stop {
        case .natural:
            #expect(result.exitCode == 0)
            #expect(result.output == "last stdout — fin")
            #expect(result.error == "last stderr — fin")
        case .timeout:
            #expect(result.exitCode != 0)
            if !worker { #expect(result.error.contains("timed out")) }
        case .cancellation:
            #expect(result.exitCode != 0)
        case .earlyResult:
            #expect(result.exitCode == 0)
            #expect(result.output == "terminal")
            #expect(diagnostics.value == "last stderr — fin")
        }
    }

    private func runFixture(
        plan: AgentRuntimeProcessLaunchPlan, root: URL, runner: AgentRuntimeProcessRunner,
        stop: Stop, worker: Bool, diagnostics: AgentLockedBuffer
    ) async -> AgentUtilityRunResult {
        if worker {
            let output = AgentLockedBuffer()
            let task = AgentTask(title: "Pipe completion", goal: "Synthetic provider")
            let result = await runner.runRuntimeProcess(
                adapter: PipeFixtureAdapter(plan: plan), prompt: "Synthetic", task: task,
                workspacePath: root.path, executablePath: plan.executablePath, homeDirectory: root.path,
                permissionPolicy: .restricted, timeoutSeconds: 2,
                onLine: { line, _ in output.append(line) }
            )
            #expect(result.timedOut == (stop == .timeout))
            return AgentUtilityRunResult(exitCode: result.exitCode, output: output.value, error: result.error ?? "")
        }
        let lineHandler: (@Sendable (String) -> AgentUtilityRunResult?)?
        if stop == .earlyResult {
            lineHandler = { _ in AgentUtilityRunResult(exitCode: 0, output: "terminal", error: "") }
        } else { lineHandler = nil }
        return await runner.runUtilityProcess(
            AgentUtilityLaunchPlan(process: plan, providerHomeDirectory: "", permissionPolicy: .restricted, timeoutSeconds: 2),
            stdoutLineHandler: lineHandler,
            stderrChunkHandler: { diagnostics.append($0) }
        )
    }

}

private struct PipeFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let plan: AgentRuntimeProcessLaunchPlan
    var unknownEvents = false
    var id: AgentRuntimeID { .claudeCode }
    let descriptor = AgentRuntimeDescriptor(id: .claudeCode, displayName: "Fixture", executableName: "fixture", installHint: "", authHint: "", defaultModels: ["fixture"], supportsAstraRunProtocol: false)
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan { plan }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        unknownEvents ? [.unknown(type: "fixture.frame")] : []
    }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
