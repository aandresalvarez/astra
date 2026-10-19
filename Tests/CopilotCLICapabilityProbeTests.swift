import Foundation
import Darwin
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot CLI capability probe", .serialized)
struct CopilotCLICapabilityProbeTests {
    @Test("A cold presentation read never starts help")
    func coldReadDoesNotSpawn() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("counter")
        try Self.writeCountingCopilot(at: executable, counter: counter, helpBody: "echo --output-format=FORMAT")
        #expect(CopilotCLIRuntime.capabilities(executablePath: executable.path) == .conservative)
        #expect(try Self.probeCount(at: counter) == 0)
    }

    @Test("Readiness does not repeat capability discovery")
    func readinessDoesNotStartHelp() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("counter")
        try Self.writeCountingCopilot(at: executable, counter: counter, helpBody: "echo --output-format=FORMAT")
        let runner = StubBinaryRunner()
        await runner.setResponse(forKey: "\(executable.path) --version",
            result: .exited(code: 0, stdout: "copilot test", stderr: ""))
        let service = RuntimeReadinessService(runner: runner, detectExecutable: { _ in executable.path },
            isExecutable: { _ in true })
        let report = await service.checkDescriptor(configuration: RuntimeReadinessConfiguration(
            runtime: .copilotCLI, claudePath: "", copilotPath: executable.path,
            claudeProvider: .anthropic, vertexProjectID: "", vertexRegion: "",
            vertexOpusModel: "", vertexSonnetModel: "", vertexHaikuModel: ""))
        #expect(report.state == .ready)
        #expect(try Self.probeCount(at: counter) == 0)
    }

    @Test("Stopping the final consumer terminates and reaps its help process")
    func finalCancellationReapsProbe() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("copilot")
        let pidFile = root.appendingPathComponent("pid")
        try Self.writeExecutable(at: executable, script: """
        #!/bin/sh
        echo $$ > \(Self.shQuote(pidFile.path))
        trap '' TERM
        exec /bin/sleep 60
        """)
        let consumer = Task { try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path) }
        defer { consumer.cancel() }
        for _ in 0..<2_400 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        consumer.cancel()
        do { _ = try await consumer.value; Issue.record("Cancelled query succeeded") }
        catch { #expect(error is CancellationError) }
        for _ in 0..<400 {
            if kill(pid, 0) == -1, errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 0)
    }

    @Test("Upgrading a symlink target invalidates the observed capabilities")
    func symlinkTargetUpgradeReprobes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("counter")
        try Self.writeCountingCopilot(at: target, counter: counter, helpBody: "echo --output-format=FORMAT")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: link.path)
        try Self.writeCountingCopilot(at: target, counter: counter, helpBody: "echo --output-format=FORMAT --effort=LEVEL")
        #expect(CopilotCLIRuntime.capabilities(executablePath: link.path) == .conservative)
        #expect(try await CopilotCLIRuntime.requiredCapabilities(executablePath: link.path).supportsReasoningEffort)
        #expect(try Self.probeCount(at: counter) == 2)
    }

    @Test("Failed or empty help is retried without changing the binary")
    func unsuccessfulHelpIsNotAnAnswer() async throws {
        for response in ["echo --output-format=FORMAT; exit 1", "exit 0"] {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("copilot")
            let counter = root.appendingPathComponent("counter")
            let recovered = root.appendingPathComponent("recovered")
            try Self.writeCountingCopilot(at: executable, counter: counter, helpBody: """
            if [ ! -f \(Self.shQuote(recovered.path)) ]; then
              \(response)
            fi
            echo --output-format=FORMAT
            """)
            do {
                _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path)
                Issue.record("Failed or empty help was accepted as an answer")
            } catch { #expect(error is CopilotCapabilityProbe.Failure) }
            try Data().write(to: recovered)
            let second = try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path)
            #expect(second.supportsOutputFormatJSON)
            #expect(try Self.probeCount(at: counter) == 2)
        }
    }

    @Test("Concurrent consumers share help and cancellation leaves the other consumer alive")
    func concurrentConsumersShareProbe() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("counter")
        let release = root.appendingPathComponent("release")
        try Self.writeCountingCopilot(at: executable, counter: counter,
            helpBody: Self.helpWaitingFor(release, then: "echo --output-format=FORMAT"))
        let first = Task { try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path) }
        let second = Task { try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path) }
        defer { first.cancel(); second.cancel() }
        // Register both waiters deterministically, not by assuming scheduler speed.
        for _ in 0..<2_400 {
            if await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 2)
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled waiter returned an answer") }
        catch { #expect(error is CancellationError) }
        #expect(await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 1)
        try Data().write(to: release)
        #expect(try await second.value.supportsOutputFormatJSON)
        #expect(try Self.probeCount(at: counter) == 1)
    }

    @Test("Each consumer has its own deadline and a timeout cannot poison a later answer")
    func independentDeadlines() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("counter")
        let release = root.appendingPathComponent("release")
        try Self.writeCountingCopilot(at: executable, counter: counter,
            helpBody: Self.helpWaitingFor(release, then: "echo --output-format=FORMAT"))
        let survivor = Task { try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path) }
        defer { survivor.cancel() }
        for _ in 0..<2_400 {
            if await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(await CopilotCapabilityProbe.shared.waiterCount(executablePath: executable.path) == 1)
        do {
            _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: executable.path, timeout: 0.1)
            Issue.record("An unreleased probe exceeded its consumer deadline")
        } catch {
            guard let failure = error as? CopilotCapabilityProbe.Failure,
                  case .timedOut = failure else {
                Issue.record("Consumer deadline must expire independently of the helper's exit: \(error)")
                return
            }
        }
        try Data().write(to: release)
        #expect(try await survivor.value.supportsOutputFormatJSON)
        #expect(try Self.probeCount(at: counter) == 1)
    }

    @Test("Repeated probes reuse the memoised result until the binary changes")
    func repeatedProbesReuseCachedCapabilities() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let copilot = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("probe-count")
        defer { CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilot.path) }

        try Self.writeCountingCopilot(
            at: copilot,
            counter: counter,
            helpBody: #"echo "--output-format=FORMAT --stream=MODE --no-ask-user""#
        )

        // Probes go through `requiredCapabilities` so a busy machine cannot turn them into
        // a timed-out fallback; the main-actor reads after it are what is being counted.
        let answered = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path)
        #expect(answered.supportsOutputFormatJSON)
        #expect(answered.supportsStreamingFlag)
        #expect(!answered.supportsReasoningEffort)

        // Admission evaluation probes twice per runtime on every debounced keystroke, so an
        // unchanged binary has to be spawned exactly once.
        for _ in 0..<5 {
            #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == answered)
        }
        #expect(try Self.probeCount(at: counter) == 1)

        // An in-place upgrade changes the binary's identity, so the memoised answer expires.
        try Self.writeCountingCopilot(
            at: copilot,
            counter: counter,
            helpBody: #"echo "--output-format=FORMAT --stream=MODE --no-ask-user --effort LEVEL""#
        )
        let upgraded = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path)
        #expect(upgraded.supportsReasoningEffort)
        #expect(try Self.probeCount(at: counter) == 2)

        // And an explicit invalidation forces a fresh probe.
        CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilot.path)
        _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path)
        #expect(try Self.probeCount(at: counter) == 3)
    }

    @Test("Help output larger than the pipe buffer is drained instead of deadlocking")
    func largeHelpOutputIsDrained() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let copilot = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("probe-count")
        defer { CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilot.path) }

        // Well past the 64 KB pipe buffer: reading only after the child exits would wedge
        // both processes forever.
        try Self.writeCountingCopilot(
            at: copilot,
            counter: counter,
            helpBody: """
            echo "--output-format=FORMAT --stream=MODE --no-ask-user --effort LEVEL"
              i=0
              while [ $i -lt 4000 ]; do
                echo "  --filler-option-$i   Padding so the help text exceeds the pipe buffer size."
                i=$((i+1))
              done
            """
        )

        let capabilities = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path)

        #expect(capabilities.supportsOutputFormatJSON)
        #expect(capabilities.supportsStreamingFlag)
        #expect(capabilities.supportsReasoningEffort)
    }

    @Test("A probe that runs out of time falls back without being memoised as the answer")
    func timedOutProbeIsNotMemoisedAsTheAnswer() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let copilot = root.appendingPathComponent("copilot")
        let counter = root.appendingPathComponent("probe-count")
        let release = root.appendingPathComponent("release")
        defer { CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilot.path) }

        try Self.writeCountingCopilot(
            at: copilot,
            counter: counter,
            helpBody: Self.helpWaitingFor(release, then: #"echo "--output-format=FORMAT --stream=MODE --no-ask-user""#)
        )

        // A real asynchronous timeout is not an answer. Presentation reads after
        // it must remain cache-only; they cannot restart a failed query.
        do {
            _ = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path, timeout: 0.1)
            Issue.record("Unreleased help returned an answer")
        } catch { #expect(error is CopilotCapabilityProbe.Failure) }
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == .conservative)
        // ...and keeps falling back without respawning the CLI on every keystroke. A probe
        // the load held off before it ran its first line leaves no count, hence at most one.
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == .conservative)
        let probesWhileHung = try Self.probeCount(at: counter)
        #expect(probesWhileHung <= 1)

        // Running out of time said nothing about the binary, so a caller that can wait asks
        // again and gets the real answer, which the main actor then reads too.
        try Data().write(to: release)
        let answered = try await CopilotCLIRuntime.requiredCapabilities(executablePath: copilot.path)
        #expect(answered.supportsOutputFormatJSON)
        #expect(answered.supportsStreamingFlag)
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == answered)
        #expect(try Self.probeCount(at: counter) == probesWhileHung + 1)
    }

    /// The main actor's read, on its own thread so a `@MainActor` test does not hold the
    /// main thread for the whole probe budget.
    static func briefCapabilitiesOffMain(executablePath: String) async -> CopilotCLICapabilities {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: CopilotCLIRuntime.capabilities(executablePath: executablePath))
            }
        }
    }

    /// A `help` body that blocks until `release` exists. After at least 30 s it gives up
    /// with empty help, which parses to something other than `.conservative`. That sits
    /// between the main actor's 5 s budget and the 60 s answer budget, so a main-actor read
    /// that waited for an answer fails the test, and load can only push the give-up later.
    static func helpWaitingFor(_ release: URL, then answer: String) -> String {
        """
          i=0
          while [ ! -f \(shQuote(release.path)) ]; do
            i=$((i+1))
            [ $i -gt 600 ] && exit 1
            sleep 0.05
          done
          \(answer)
        """
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeCountingCopilot(at url: URL, counter: URL, helpBody: String) throws {
        try writeExecutable(at: url, script: """
        #!/bin/sh
        echo probe >> \(shQuote(counter.path))
        if [ "$1" = "help" ]; then
        \(helpBody)
          exit 0
        fi
        exit 0
        """)
    }

    private static func writeExecutable(at url: URL, script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func probeCount(at counter: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: counter.path) else { return 0 }
        return try String(contentsOf: counter, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
