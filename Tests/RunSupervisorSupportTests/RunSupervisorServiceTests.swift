import ASTRACore
import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor service", .serialized)
struct RunSupervisorServiceTests {
    @Test("normal and nonzero exits preserve ordered output and typed termination evidence")
    func normalAndNonzeroExit() throws {
        let fixture = try makeFixture("exit")
        let payload = try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            workingDirectory: fixture.rootURL.path
        )
        let service = RunSupervisorService(root: fixture.root)
        #expect(try service.run(payload) == .launched(exitCode: 7))

        let runDirectory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let spool = try RunSupervisorEventSpool(
            directory: runDirectory,
            capability: payload.capability
        )
        let events = try spool.replay(after: 0)
        #expect(events.filter { $0.kind == .standardOutput }.compactMap(\.payload.data).reduce(Data(), +) == Data("out".utf8))
        #expect(events.filter { $0.kind == .standardError }.compactMap(\.payload.data).reduce(Data(), +) == Data("err".utf8))
        let exited = try #require(events.last { $0.kind == .providerExited })
        #expect(exited.payload.exitCode == 7)
        #expect(exited.payload.terminationReason == .exited)
        #expect(exited.payload.terminationSignal == nil)
        #expect(!events.contains { $0.kind == .cancellationConfirmed })

        let cursor = try #require(events.first { $0.kind == .standardOutput }).sequence
        #expect(try spool.replay(after: cursor).allSatisfy { $0.sequence > cursor })
    }

    @Test("provider signal termination survives lifetime watchdog wrapping")
    func providerSignalTerminationSurvivesWatchdog() throws {
        let fixture = try makeFixture("signal")
        let payload = try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", "kill -SEGV $$"],
            workingDirectory: fixture.rootURL.path,
            identitySeed: 105
        )
        let service = RunSupervisorService(root: fixture.root)
        #expect(try service.run(payload) == .launched(exitCode: 128 + SIGSEGV))

        let runDirectory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let spool = try RunSupervisorEventSpool(
            directory: runDirectory,
            capability: payload.capability
        )
        let exited = try #require(try spool.replay(after: 0).last { $0.kind == .providerExited })
        #expect(exited.payload.exitCode == 128 + SIGSEGV)
        #expect(exited.payload.terminationReason == .signaled)
        #expect(exited.payload.terminationSignal == SIGSEGV)
    }

    @Test("stdin is ephemeral and graceful cancellation remains unsupported until explicit immediate termination")
    func stdinGracefulAndImmediateCancellation() async throws {
        let fixture = try makeFixture("control")
        let payload = try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; IFS= read -r line; printf '%s' \"$line\"; while :; do /bin/sleep 1; done"],
            workingDirectory: fixture.rootURL.path,
            identitySeed: 110
        )
        let service = RunSupervisorService(root: fixture.root)
        let runTask = Task.detached { try service.run(payload) }
        let connected: (directory: RunSupervisorRunDirectory, discovery: RunSupervisorDiscoveryRecord)
        do {
            connected = try waitForConnection(payload: payload, root: fixture.root)
        } catch {
            _ = try await runTask.value
            throw error
        }

        let secretInput = "ephemeral-stdin-secret"
        #expect(try send(
            .init(kind: .writeStandardInput, standardInputLine: secretInput),
            payload: payload,
            directory: connected.directory
        ).accepted)
        #expect(try send(
            .init(kind: .cancel, cancellationIntent: .graceful),
            payload: payload,
            directory: connected.directory
        ).accepted)
        let gracefulEvents = try replay(payload: payload, directory: connected.directory)
        #expect(gracefulEvents.contains { $0.kind == .cancellationUnsupported })
        #expect(!gracefulEvents.contains { $0.kind == .terminationStarted })

        #expect(try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        ).accepted)
        let outcome = try await runTask.value
        guard case .launched = outcome else { Issue.record("Expected a launched supervisor"); return }

        let spool = try RunSupervisorEventSpool(
            directory: connected.directory,
            capability: payload.capability
        )
        let events = try spool.replay(after: 0)
        let persisted = try RunSupervisorWireCoding.encode(events)
        #expect(!String(decoding: persisted, as: UTF8.self).contains(secretInput))
        #expect(events.contains { $0.kind == .standardInputAccepted })
        #expect(events.contains { $0.kind == .terminationStarted })
        #expect(events.contains { $0.kind == .cancellationConfirmed })
        let exited = try #require(events.last { $0.kind == .providerExited })
        #expect(exited.payload.terminationReason == .signaled)
        #expect(exited.payload.terminationSignal != nil)
    }

    @Test("invalid bootstrap fails before run-directory and provider side effects")
    func failedBootstrapHasNoOrphan() throws {
        let fixture = try makeFixture("badboot")
        let launcher = CountingLauncher()
        let service = RunSupervisorService(root: fixture.root, launcher: launcher)
        let valid = try RunSupervisorTestSupport.payload(arguments: ["valid"], identitySeed: 120)
        let invalid = RunSupervisorBootstrapPayload(
            manifest: valid.manifest,
            manifestSHA256: valid.manifestSHA256,
            expectedIdentity: valid.expectedIdentity,
            arguments: ["changed"],
            environment: valid.environment,
            capability: valid.capability
        )
        #expect(throws: RunSupervisorError.invalidArgumentDigest) {
            try service.run(invalid)
        }
        #expect(launcher.launchCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path).isEmpty)
    }

    @Test("output read failures are surfaced and force provider termination")
    func outputReadFailureIsNotEOF() throws {
        let fixture = try makeFixture("readerr")
        let process = ClosedOutputProcess()
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: SingleProcessLauncher(process: process)
        )
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 125)
        #expect(throws: RunSupervisorError.outputPersistenceFailed) {
            try service.run(payload)
        }
        #expect(process.terminationRequested)
    }

    @Test("a natural exit racing immediate cancellation is not falsely confirmed as cancelled")
    func naturalExitWinsCancellationRace() async throws {
        let fixture = try makeFixture("race")
        let process = NaturalExitRaceProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 130)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: NaturalExitRaceLauncher(process: process)
        )
        let runTask = Task.detached { try service.run(payload) }
        let connected = try waitForConnection(payload: payload, root: fixture.root)

        let response = try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        )
        #expect(!response.accepted)
        #expect(try await runTask.value == .launched(exitCode: 0))

        let spool = try RunSupervisorEventSpool(
            directory: connected.directory,
            capability: payload.capability
        )
        let events = try spool.replay(after: 0)
        #expect(events.contains { $0.kind == .cancellationRequested })
        #expect(!events.contains { $0.kind == .terminationStarted })
        #expect(!events.contains { $0.kind == .cancellationConfirmed })
        let exited = try #require(events.last { $0.kind == .providerExited })
        #expect(exited.payload.exitCode == 0)
        #expect(exited.payload.terminationSignal == nil)
        #expect(exited.payload.terminationReason == .exited)
    }

    @Test("synchronous immediate termination is linearized before terminal evidence")
    func synchronousImmediateTerminationIsLinearized() async throws {
        let fixture = try makeFixture("synccancel")
        let process = SynchronousCancellationProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 132)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: SynchronousCancellationLauncher(process: process)
        )
        let runTask = Task.detached { try service.run(payload) }
        let connected = try waitForConnection(payload: payload, root: fixture.root)

        #expect(try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        ).accepted)
        #expect(try await runTask.value == .launched(exitCode: 143))

        let spool = try RunSupervisorEventSpool(
            directory: connected.directory,
            capability: payload.capability
        )
        let orderedKinds = try spool.replay(after: 0).map(\.kind).filter {
            [.cancellationRequested, .terminationStarted, .cancellationConfirmed, .providerExited]
                .contains($0)
        }
        #expect(orderedKinds == [
            .cancellationRequested,
            .terminationStarted,
            .cancellationConfirmed,
            .providerExited,
        ])
    }

    @Test("an immediate exit persists provider start before output and terminal last")
    func immediateExitPreservesLifecycleOrdering() throws {
        let fixture = try makeFixture("immediate-order")
        let process = ImmediateOutputExitProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 133)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: ImmediateOutputExitLauncher(process: process)
        )

        #expect(try service.run(payload) == .launched(exitCode: 0))

        let directory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let events = try RunSupervisorEventSpool(
            directory: directory,
            capability: payload.capability
        ).replay(after: 0)
        let kinds = events.map(\.kind)
        let ready = try #require(kinds.firstIndex(of: .supervisorReady))
        let started = try #require(kinds.firstIndex(of: .providerStarted))
        let output = try #require(kinds.firstIndex(of: .standardOutput))
        let exited = try #require(kinds.firstIndex(of: .providerExited))
        #expect(ready < started)
        #expect(started < output)
        #expect(output < exited)
        #expect(events.last?.kind == .providerExited)
    }

    @Test("terminal persistence waits for delayed output drain")
    func terminalWaitsForDelayedOutputDrain() async throws {
        let fixture = try makeFixture("delayed-drain")
        let process = DelayedDrainExitProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 134)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: DelayedDrainExitLauncher(process: process)
        )
        let runTask = Task.detached { try service.run(payload) }

        #expect(process.waitUntilOutputReaderRequested())
        try process.emitAndClose(Data("delayed-output".utf8))
        #expect(try await runTask.value == .launched(exitCode: 0))

        let directory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let events = try RunSupervisorEventSpool(
            directory: directory,
            capability: payload.capability
        ).replay(after: 0)
        #expect(events.filter { $0.kind == .standardOutput }
            .compactMap(\.payload.data).reduce(Data(), +) == Data("delayed-output".utf8))
        #expect(events.last?.kind == .providerExited)
    }

    @Test("broken stdin operations never produce durable acceptance evidence")
    func brokenStdinIsNotAccepted() async throws {
        let fixture = try makeFixture("stdinerr")
        let process = BrokenStdinProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 135)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: BrokenStdinLauncher(process: process)
        )
        let runTask = Task.detached { try service.run(payload) }
        let connected = try waitForConnection(payload: payload, root: fixture.root)

        #expect(try !send(
            .init(kind: .writeStandardInput, standardInputLine: "not-delivered"),
            payload: payload,
            directory: connected.directory
        ).accepted)
        #expect(try !send(
            .init(kind: .closeStandardInput),
            payload: payload,
            directory: connected.directory
        ).accepted)
        let beforeCancellation = try replay(payload: payload, directory: connected.directory)
        #expect(!beforeCancellation.contains { $0.kind == .standardInputAccepted })
        #expect(!beforeCancellation.contains { $0.kind == .standardInputClosed })

        #expect(try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        ).accepted)
        _ = try await runTask.value
    }

    @Test("a blocked stdin write does not prevent immediate cancellation")
    func blockedStdinDoesNotBlockCancellation() async throws {
        let fixture = try makeFixture("stdin-block")
        let process = BlockingStdinProcess()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 136)
        let service = RunSupervisorService(
            root: fixture.root,
            launcher: BlockingStdinLauncher(process: process)
        )
        let runTask = Task.detached { try service.run(payload) }
        let connected = try waitForConnection(payload: payload, root: fixture.root)
        let writeTask = Task.detached {
            try self.send(
                .init(kind: .writeStandardInput, standardInputLine: "blocked"),
                payload: payload,
                directory: connected.directory
            )
        }
        #expect(process.waitUntilWriteBlocked())

        #expect(try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        ).accepted)
        #expect(try await !writeTask.value.accepted)
        #expect(try await runTask.value == .launched(exitCode: 143))
    }

    @Test("hard supervision limit terminates a provider that keeps producing progress")
    func hardTimeoutIsEnforced() throws {
        try assertTimeout(
            policy: .init(hardTimeoutSeconds: 1, idleProgressTimeoutSeconds: 1),
            script: "while :; do printf x; /bin/sleep 0.1; done",
            expectedWatchdogEvent: .hardTimeoutExceeded,
            identitySeed: 141
        )
    }

    @Test("idle supervision limit terminates a quiet provider before its hard limit")
    func idleTimeoutIsEnforced() throws {
        try assertTimeout(
            policy: .init(hardTimeoutSeconds: 3, idleProgressTimeoutSeconds: 1),
            script: "/bin/sleep 10",
            expectedWatchdogEvent: .idleProgressTimeoutExceeded,
            identitySeed: 142
        )
    }

    private func assertTimeout(
        policy: ExecutionSupervisionPolicySnapshot,
        script: String,
        expectedWatchdogEvent: RunSupervisorEventKind,
        identitySeed: UInt8
    ) throws {
        let fixture = try makeFixture("timeout")
        let payload = try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            supervisionPolicy: policy,
            identitySeed: identitySeed
        )
        let started = Date()
        let outcome = try RunSupervisorService(root: fixture.root).run(payload)
        guard case .launched(let exitCode) = outcome else {
            Issue.record("Expected a newly launched provider")
            return
        }
        #expect(exitCode != 0)
        // The watchdog fires at the earliest policy deadline. Process-group
        // termination then permits the normal three-second graceful window
        // before SIGKILL, so the assertion includes that bounded escalation.
        let firstDeadline = min(policy.hardTimeoutSeconds, policy.idleProgressTimeoutSeconds)
        #expect(Date().timeIntervalSince(started) < TimeInterval(firstDeadline) + 4)

        let directory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let events = try RunSupervisorEventSpool(
            directory: directory,
            capability: payload.capability
        ).replay(after: 0)
        let terminal = try #require(events.last { $0.kind == .providerExited })
        #expect(terminal.payload.terminationReason == .signaled)
        #expect(terminal.payload.terminationSignal != nil)
        let watchdog = try #require(events.last { $0.kind == expectedWatchdogEvent })
        #expect(watchdog.sequence < terminal.sequence)
        #expect(events.filter {
            $0.kind == .hardTimeoutExceeded || $0.kind == .idleProgressTimeoutExceeded
        }.count == 1)
    }

    @Test("a failed diagnostic PID discovery update cannot suppress terminal evidence")
    func diagnosticDiscoveryFailureStillPersistsTerminalEvidence() throws {
        let fixture = try makeFixture("pid-write")
        let fileSystem = FailingSecondDiscoveryWriteFileSystem()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 139)
        let service = RunSupervisorService(root: fixture.root, fileSystem: fileSystem)

        #expect(try service.run(payload) == .launched(exitCode: 0))
        #expect(fileSystem.writeCount == 2)
        let directory = try fixture.root.openExecutionDirectory(payload.manifest.executionID)
        let events = try RunSupervisorEventSpool(
            directory: directory,
            capability: payload.capability
        ).replay(after: 0)
        #expect(events.contains { $0.kind == .providerStarted })
        #expect(events.last?.kind == .providerExited)
    }

    @Test("close stdin is rejected while no live provider has been installed")
    func closeStdinWithoutLiveProcess() async throws {
        let fixture = try makeFixture("nolivestd")
        let launcher = BlockingLauncher()
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 138)
        let service = RunSupervisorService(root: fixture.root, launcher: launcher)
        let runTask = Task.detached { try service.run(payload) }
        defer { launcher.allowLaunch() }
        let connected = try waitForConnection(payload: payload, root: fixture.root)
        #expect(launcher.waitUntilBlocked())

        let response = try send(
            .init(kind: .closeStandardInput),
            payload: payload,
            directory: connected.directory
        )
        #expect(!response.accepted)
        #expect(try !replay(payload: payload, directory: connected.directory)
            .contains { $0.kind == .standardInputClosed })

        launcher.allowLaunch()
        #expect(try await runTask.value == .launched(exitCode: 0))
    }

    private func makeFixture(_ suffix: String) throws -> (
        rootURL: URL,
        root: RunSupervisorTrustedRoot
    ) {
        let url = try RunSupervisorTestSupport.temporaryDirectory(suffix)
        return (url, try RunSupervisorTrustedRoot(path: url.path))
    }

    private func waitForConnection(
        payload: RunSupervisorBootstrapPayload,
        root: RunSupervisorTrustedRoot
    ) throws -> (directory: RunSupervisorRunDirectory, discovery: RunSupervisorDiscoveryRecord) {
        let fileSystem = DarwinRunSupervisorFileSystem()
        var directory: RunSupervisorRunDirectory?
        var discovery: RunSupervisorDiscoveryRecord?
        let ready = RunSupervisorTestSupport.waitUntil(timeout: 5) {
            if directory == nil {
                directory = try? root.openExecutionDirectory(payload.manifest.executionID)
            }
            guard let directory else { return false }
            discovery = try? fileSystem.readDiscovery(in: directory)
            guard let discovery else { return false }
            return DarwinRunSupervisorControlClient().authenticate(
                discovery: discovery,
                directory: directory,
                capability: payload.capability
            )
        }
        guard ready, let directory, let discovery else {
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        return (directory, discovery)
    }

    private func send(
        _ action: RunSupervisorControlAction,
        payload: RunSupervisorBootstrapPayload,
        directory: RunSupervisorRunDirectory
    ) throws -> RunSupervisorControlResponse {
        try DarwinRunSupervisorControlClient().send(
            RunSupervisorControlAuthentication.makeRequest(
                executionID: payload.manifest.executionID,
                action: action,
                capability: payload.capability
            ),
            directory: directory
        )
    }

    private func replay(
        payload: RunSupervisorBootstrapPayload,
        directory: RunSupervisorRunDirectory
    ) throws -> [RunSupervisorEvent] {
        var cursor: UInt64 = 0
        var events: [RunSupervisorEvent] = []
        while true {
            let response = try send(
                .init(kind: .replay, afterSequence: cursor),
                payload: payload,
                directory: directory
            )
            events.append(contentsOf: response.events)
            guard let nextCursor = response.events.last?.sequence,
                  nextCursor > cursor,
                  nextCursor < response.lastSequence else {
                return events
            }
            cursor = nextCursor
        }
    }
}

private final class CountingLauncher: RunSupervisorProviderLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var launchCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        lock.lock(); count += 1; lock.unlock()
        return ClosedOutputProcess()
    }
}

private struct SingleProcessLauncher: RunSupervisorProviderLaunching {
    let process: ClosedOutputProcess
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess { process }
}

private struct NaturalExitRaceLauncher: RunSupervisorProviderLaunching {
    let process: NaturalExitRaceProcess
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

private struct BrokenStdinLauncher: RunSupervisorProviderLaunching {
    let process: BrokenStdinProcess
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

private struct BlockingStdinLauncher: RunSupervisorProviderLaunching {
    let process: BlockingStdinProcess
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

private final class BlockingStdinProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeEntered = DispatchSemaphore(value: 0)
    private let writeRelease = DispatchSemaphore(value: 0)
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var terminated = false

    init() {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_997 }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void) {
        lock.withLock { self.handler = handler }
    }
    func run() throws {}
    func writeStandardInputLine(_ line: String) throws {
        writeEntered.signal()
        _ = writeRelease.wait(timeout: .now() + 5)
        throw RunSupervisorError.systemCall("write provider stdin", EPIPE)
    }
    func closeStandardInput() throws -> Bool { false }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool {
        let callback: (@Sendable (RunSupervisorProcessTermination) -> Void)? = lock.withLock {
            guard !terminated else { return nil }
            terminated = true
            return handler
        }
        guard let callback else { return false }
        writeRelease.signal()
        callback(.init(exitCode: 143, signal: SIGTERM))
        return true
    }
    func waitUntilWriteBlocked() -> Bool {
        writeEntered.wait(timeout: .now() + 5) == .success
    }
}

private final class FailingSecondDiscoveryWriteFileSystem: RunSupervisorFileSystem, @unchecked Sendable {
    private let base = DarwinRunSupervisorFileSystem()
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func readDiscovery(in directory: RunSupervisorRunDirectory) throws -> RunSupervisorDiscoveryRecord? {
        try base.readDiscovery(in: directory)
    }

    func writeDiscovery(
        _ record: RunSupervisorDiscoveryRecord,
        in directory: RunSupervisorRunDirectory
    ) throws {
        let count = lock.withLock { () -> Int in
            writes += 1
            return writes
        }
        if count == 2 { throw RunSupervisorError.systemCall("injected discovery write", EIO) }
        try base.writeDiscovery(record, in: directory)
    }

    func removeControlSocket(in directory: RunSupervisorRunDirectory) throws {
        try base.removeControlSocket(in: directory)
    }
}

private final class BlockingLauncher: RunSupervisorProviderLaunching, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        entered.signal()
        release.wait()
        return ImmediateExitProcess()
    }

    func waitUntilBlocked() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func allowLaunch() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        release.signal()
    }
}

private final class ImmediateExitProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?

    init() {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { nil }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void) {
        self.handler = handler
    }
    func run() throws { handler?(.init(exitCode: 0, signal: nil)) }
    func writeStandardInputLine(_ line: String) throws {
        throw RunSupervisorError.alreadyRunningOrInDoubt
    }
    func closeStandardInput() throws -> Bool { throw RunSupervisorError.alreadyRunningOrInDoubt }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool { false }
}

private final class BrokenStdinProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var terminated = false

    init() {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_998 }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func run() throws {}
    func writeStandardInputLine(_ line: String) throws {
        throw RunSupervisorError.systemCall("write provider stdin", EPIPE)
    }
    func closeStandardInput() throws -> Bool {
        throw RunSupervisorError.systemCall("close provider stdin", EPIPE)
    }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool {
        lock.lock()
        guard !terminated else { lock.unlock(); return false }
        terminated = true
        let handler = self.handler
        lock.unlock()
        handler?(.init(exitCode: 143, signal: SIGTERM))
        return true
    }
}

private final class NaturalExitRaceProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var exited = false

    init() {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_999 }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func run() throws {}
    func writeStandardInputLine(_ line: String) throws {}
    func closeStandardInput() throws -> Bool { true }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool {
        lock.lock()
        guard !exited else { lock.unlock(); return false }
        exited = true
        let handler = self.handler
        lock.unlock()
        handler?(.init(exitCode: 0, signal: nil))
        return false
    }
}

private final class ClosedOutputProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutHandle = FileHandle(fileDescriptor: 999_998, closeOnDealloc: false)
    private let stderrHandle = FileHandle(fileDescriptor: 999_999, closeOnDealloc: false)
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var terminated = false

    var stdoutFileHandle: FileHandle { stdoutHandle }
    var stderrFileHandle: FileHandle { stderrHandle }
    var processIdentifierDiagnostic: Int32? { nil }
    var terminationRequested: Bool { lock.lock(); defer { lock.unlock() }; return terminated }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func run() throws {}
    func writeStandardInputLine(_ line: String) throws {}
    func closeStandardInput() throws -> Bool { true }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool {
        lock.lock()
        guard !terminated else { lock.unlock(); return false }
        terminated = true
        let handler = self.handler
        lock.unlock()
        handler?(.init(exitCode: 143, signal: SIGTERM))
        return true
    }
}
