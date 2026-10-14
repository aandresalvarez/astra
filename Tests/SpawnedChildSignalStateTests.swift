import Darwin
import Foundation
import Testing
@testable import ASTRA
import HostControlToolSupport

/// A child that traps SIGTERM and then sends it to itself. It prints `caught`
/// only if SIGTERM can reach it. If its inherited mask blocks SIGTERM, the
/// signal stays pending. If SIGTERM was ignored on entry, the shell refuses
/// the trap.
private let trapsItsOwnSIGTERM = #"trap 'echo caught' TERM; kill -TERM $$; echo after"#

/// Each spawner here runs with SIGTERM blocked on the spawning thread. That is
/// what any GCD worker or Swift concurrency pool thread already has, and those
/// are the threads production calls these spawners from. The child must not
/// inherit that mask, or the spawner's own `terminate()` can never stop it
/// gracefully: SIGTERM stays pending and only the SIGKILL that follows lands.
@Suite("Spawned children start with default signal state")
struct SpawnedChildSignalStateTests {
    @Test("Agent provider process")
    func agentProviderProcess() async {
        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", trapsItsOwnSIGTERM],
            currentDirectory: NSTemporaryDirectory(),
            environment: ["PATH": "/bin:/usr/bin"],
            stdinMode: .closed
        )

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try withSIGTERMBlockedOnThisThread { try process.run() }
            } catch {
                continuation.resume(returning: -1)
            }
        }
        let output = String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self)

        #expect(exitCode == 0)
        #expect(output == "caught\nafter\n")
    }

    @Test("Host-control command")
    func hostControlCommand() {
        // The timeout is only a hang breaker: the child exits on its own
        // either way, printing `after` with or without `caught`.
        let result = withSIGTERMBlockedOnThisThread {
            HostControlProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", trapsItsOwnSIGTERM],
                timeoutSeconds: 120,
                environment: [:]
            )
        }

        #expect(result.exitCode == 0)
        #expect(result.stdout == "caught\nafter\n")
    }

    /// Blocks SIGTERM on the calling thread for the duration of `body`. The
    /// spawn inside it then starts from the mask production's GCD threads
    /// have, whichever thread the test itself landed on.
    private func withSIGTERMBlockedOnThisThread<T>(_ body: () throws -> T) rethrows -> T {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return try body()
    }
}
