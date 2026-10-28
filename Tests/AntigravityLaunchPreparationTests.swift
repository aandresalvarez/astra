import Darwin
import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Antigravity launch preparation")
@MainActor
struct AntigravityLaunchPreparationTests {
    @Test("The probe deadline covers inherited pipes and ignored termination", arguments: [false, true])
    func deadlineIncludesOutputDrain(ignoreTermination: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let pidFile = harness.rootURL.appendingPathComponent("probe.pid")
        let body = ignoreTermination
            ? "trap '' TERM; echo $$ > '\(pidFile.path)'; printf '%s\\n' '--output-format'; exec /bin/sleep 30"
            : "(/bin/sleep 30) & echo $! > '\(pidFile.path)'; printf '%s\\n' '--output-format'; exit 0"
        let executable = try harness.writeExecutable(named: "probe", script: "#!/bin/sh\n\(body)\n")
        defer { killRecordedProcess(pidFile) }
        let defaults = InMemoryDefaults()
        let started = ContinuousClock.now
        let supported = await AntigravityCLIRuntime.warmStructuredOutputSupportBeforeLaunch(
            executablePath: executable, providerHomeDirectory: "", defaults: defaults, timeoutSeconds: 0.5)

        #expect(started.duration(to: .now) < .seconds(8), "The runner must not wait for the 30-second pipe holder")
        #expect(!supported, "A deadline breach must not cache even a partial valid-looking answer")
        #expect(AntigravityCLIRuntime.cachedStructuredOutputVerdict(executablePath: executable, defaults: defaults) == nil)
        let pid = try readPID(pidFile)
        let stopped = await waitUntil { kill(pid, 0) != 0 }
        #expect(stopped, "Timeout must terminate the probe process group")
    }

    @Test("Large help output drains concurrently and truncated capabilities are not cached")
    func truncatedHelpIsNotCached() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let executable = try harness.writeExecutable(named: "probe", script: """
        #!/bin/sh
        printf '%s\\n' '--output-format'
        /usr/bin/head -c 1100000 /dev/zero
        /usr/bin/head -c 1100000 /dev/zero >&2
        """)
        let defaults = InMemoryDefaults()
        let supported = await AntigravityCLIRuntime.warmStructuredOutputSupportBeforeLaunch(
            executablePath: executable, providerHomeDirectory: "", defaults: defaults)
        #expect(!supported)
        #expect(AntigravityCLIRuntime.cachedStructuredOutputVerdict(executablePath: executable, defaults: defaults) == nil)
    }

    @Test("Cancelling a worker during the real launch probe settles without launching the provider", arguments: [false, true])
    func cancellationDuringWorkerPreparation(cancelCaller: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let pidFile = harness.rootURL.appendingPathComponent("probe.pid")
        let launchedFile = harness.rootURL.appendingPathComponent("provider-launched")
        let executable = try harness.writeExecutable(named: "agy", script: """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          trap '' TERM
          echo $$ > '\(pidFile.path)'
          exec /bin/sleep 30
        fi
        : > '\(launchedFile.path)'
        printf '%s\\n' 'Finished the requested answer.'
        """)
        defer { killRecordedProcess(pidFile) }
        let defaults = InMemoryDefaults()
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: executable)
        worker.antigravityLaunchPreparation = AntigravityLaunchPreparation(defaults: defaults)
        let task = harness.makeTask(runtime: .antigravityCLI, goal: "Explain a concept", model: "Gemini 3.5 Flash")
        let execution = Task { await harness.execute(task: task, worker: worker) }
        defer { execution.cancel() }
        let started = await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
        #expect(started, "Must exercise the real probe inside worker execution")
        guard started else { return }
        if cancelCaller { execution.cancel() } else { worker.cancel() }
        _ = await execution.value

        #expect(!worker.isRunning)
        #expect(task.status == .cancelled)
        #expect(task.runs.last?.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: launchedFile.path))
        #expect(AntigravityCLIRuntime.cachedStructuredOutputVerdict(executablePath: executable, defaults: defaults) == nil)
        let pid = try readPID(pidFile)
        let stopped = await waitUntil { kill(pid, 0) != 0 }
        #expect(stopped)
    }

    @Test("A timed-out help probe releases the worker to complete the task")
    func workerContinuesAfterProbeDeadline() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let pidFile = harness.rootURL.appendingPathComponent("probe.pid")
        let executable = try harness.writeExecutable(named: "agy", script: """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          /bin/sleep 30 &
          echo $! > '\(pidFile.path)'
          printf '%s\\n' '--output-format'
          exit 0
        fi
        printf '%s\\n' 'Two plus two is four.'
        """)
        defer { killRecordedProcess(pidFile) }
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: executable)
        worker.antigravityLaunchPreparation = AntigravityLaunchPreparation(
            defaults: InMemoryDefaults(), timeoutSeconds: 0.5)
        let task = harness.makeTask(runtime: .antigravityCLI, goal: "Explain two plus two in one sentence", model: "Gemini 3.5 Flash")
        let started = ContinuousClock.now
        _ = await harness.execute(task: task, worker: worker)

        #expect(started.duration(to: .now) < .seconds(10))
        #expect(!worker.isRunning)
        #expect(task.status == .completed)
        #expect(task.runs.last?.status == .completed)
        let pid = try readPID(pidFile)
        let stopped = await waitUntil { kill(pid, 0) != 0 }
        #expect(stopped)
    }

    private func readPID(_ file: URL) throws -> pid_t {
        try #require(pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func killRecordedProcess(_ file: URL) {
        if let pid = try? readPID(file), pid > 0 { _ = kill(pid, SIGKILL) }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}
