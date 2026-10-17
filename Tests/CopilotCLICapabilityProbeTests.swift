import Foundation
import Testing
@testable import ASTRA

@Suite("Copilot CLI capability probe", .serialized)
struct CopilotCLICapabilityProbeTests {
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

        // Probes go through `answeredCapabilities` so a busy machine cannot turn them into
        // a timed-out fallback; the main-actor reads after it are what is being counted.
        let answered = await CopilotCLIRuntime.answeredCapabilities(executablePath: copilot.path)
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
        let upgraded = await CopilotCLIRuntime.answeredCapabilities(executablePath: copilot.path)
        #expect(upgraded.supportsReasoningEffort)
        #expect(try Self.probeCount(at: counter) == 2)

        // And an explicit invalidation forces a fresh probe.
        CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilot.path)
        _ = await CopilotCLIRuntime.answeredCapabilities(executablePath: copilot.path)
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

        let capabilities = await CopilotCLIRuntime.answeredCapabilities(executablePath: copilot.path)

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

        // `help` cannot answer before the release, so the main actor's read falls back
        // instead of stalling on it, however fast or slow the machine is...
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == .conservative)
        // ...and keeps falling back without respawning the CLI on every keystroke. A probe
        // the load held off before it ran its first line leaves no count, hence at most one.
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == .conservative)
        let probesWhileHung = try Self.probeCount(at: counter)
        #expect(probesWhileHung <= 1)

        // Running out of time said nothing about the binary, so a caller that can wait asks
        // again and gets the real answer, which the main actor then reads too.
        try Data().write(to: release)
        let answered = await CopilotCLIRuntime.answeredCapabilities(executablePath: copilot.path)
        #expect(answered.supportsOutputFormatJSON)
        #expect(answered.supportsStreamingFlag)
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path) == answered)
        #expect(try Self.probeCount(at: counter) == probesWhileHung + 1)
    }

    @Test("Only a Copilot launch waits on the Copilot capability probe")
    func onlyCopilotLaunchesWarmTheProbe() async throws {
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

        // Admission reads every runtime's profile, so a Claude launch must not stop to
        // ask an installed Copilot anything.
        await CopilotCLIRuntime.warmBeforeLaunch(runtime: .claudeCode, executablePath: copilot.path)
        #expect(try Self.probeCount(at: counter) == 0)

        // A Copilot launch gets the answer before its main-actor reads.
        await CopilotCLIRuntime.warmBeforeLaunch(runtime: .copilotCLI, executablePath: copilot.path)
        #expect(try Self.probeCount(at: counter) == 1)
        #expect(CopilotCLIRuntime.capabilities(executablePath: copilot.path).supportsOutputFormatJSON)
        #expect(try Self.probeCount(at: counter) == 1)
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
