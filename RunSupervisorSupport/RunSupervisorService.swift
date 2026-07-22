import ASTRACore
import Darwin
import Foundation
import OSLog

private let runSupervisorServiceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.coral.ASTRA",
    category: "RunSupervisorService"
)

public enum RunSupervisorServiceOutcome: Equatable, Sendable {
    case launched(exitCode: Int32)
    case existingLive
}

public final class RunSupervisorService: @unchecked Sendable {
    private let root: RunSupervisorTrustedRoot
    private let fileSystem: any RunSupervisorFileSystem
    private let launcher: any RunSupervisorProviderLaunching
    private let socketFactory: any RunSupervisorSocketServerFactory
    private let livenessProbe: any RunSupervisorLivenessProbing
    private let clock: any RunSupervisorClock
    private let spoolMaximumBytes: Int
    private let spoolCriticalReserveBytes: Int
    /// Serializes lifecycle evidence that can race provider termination.
    /// The process callback only stages raw termination evidence; this lock
    /// orders control effects before the terminal event is persisted.
    private let lifecycleEventLock = NSLock()
    private let stateLock = NSLock()
    private var process: (any RunSupervisorOwnedProcess)?
    private var spool: RunSupervisorEventSpool?
    private var controlState = ExecutionControlState()
    private var immediateTerminationIssued = false

    public init(
        root: RunSupervisorTrustedRoot,
        fileSystem: any RunSupervisorFileSystem = DarwinRunSupervisorFileSystem(),
        launcher: any RunSupervisorProviderLaunching = DarwinRunSupervisorProviderLauncher(),
        socketFactory: any RunSupervisorSocketServerFactory = DarwinRunSupervisorSocketServerFactory(),
        livenessProbe: any RunSupervisorLivenessProbing = DarwinRunSupervisorControlClient(),
        clock: any RunSupervisorClock = SystemRunSupervisorClock(),
        spoolMaximumBytes: Int = RunSupervisorEventSpool.defaultMaximumBytes,
        spoolCriticalReserveBytes: Int = RunSupervisorEventSpool.defaultCriticalReserveBytes
    ) {
        self.root = root
        self.fileSystem = fileSystem
        self.launcher = launcher
        self.socketFactory = socketFactory
        self.livenessProbe = livenessProbe
        self.clock = clock
        self.spoolMaximumBytes = spoolMaximumBytes
        self.spoolCriticalReserveBytes = spoolCriticalReserveBytes
    }

    public func run(_ payload: RunSupervisorBootstrapPayload) throws -> RunSupervisorServiceOutcome {
        // All payload and identity checks precede run-directory or process side effects.
        try RunSupervisorBootstrapValidator.validate(payload)
        let acquisition = try root.acquireExecutionDirectory(payload.manifest.executionID)
        let directory = acquisition.directory
        let existing = try fileSystem.readDiscovery(in: directory)
        let live = existing.map {
            livenessProbe.authenticate(discovery: $0, directory: directory, capability: payload.capability)
        } ?? false
        switch try RunSupervisorAdmission.decide(
            payload: payload,
            existing: existing,
            wasDirectoryCreated: acquisition.wasCreated,
            authenticatedLiveness: live
        ) {
        case .existingLive:
            return .existingLive
        case .launchNew:
            break
        }

        let spool = try RunSupervisorEventSpool(
            directory: directory,
            capability: payload.capability,
            maximumBytes: spoolMaximumBytes,
            criticalReserveBytes: spoolCriticalReserveBytes,
            clock: clock
        )
        stateLock.lock(); self.spool = spool; stateLock.unlock()
        // This defer is registered before the socket defer below. Swift's LIFO
        // ordering therefore guarantees socket quiescence before ownership is
        // released on every success and error path.
        defer {
            stateLock.lock(); self.spool = nil; stateLock.unlock()
            spool.releaseOwnership()
        }
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: payload.manifest.executionID,
            capability: payload.capability,
            clock: clock
        )
        let server = try socketFactory.makeServer(directory: directory, authenticator: authenticator)
        try fileSystem.removeControlSocket(in: directory)
        try server.start { [weak self] action in
            guard let self else {
                throw RunSupervisorError.alreadyRunningOrInDoubt
            }
            return try self.handle(action)
        }
        defer { server.stop() }

        let discovery = RunSupervisorDiscoveryRecord(
            identity: payload.expectedIdentity,
            manifestSHA256: payload.manifestSHA256,
            launchAuthenticator: try RunSupervisorDigests.launchAuthenticator(
                payload: payload,
                capability: payload.capability
            ),
            capabilitySHA256: try RunSupervisorDigests.capability(payload.capability),
            socketName: server.socketName,
            supervisorPIDDiagnostic: getpid(),
            createdAt: clock.persistedNow()
        )
        try fileSystem.writeDiscovery(discovery, in: directory)
        _ = try spool.appendCritical(.supervisorReady)

        let launchRequest = RunSupervisorProviderLaunchRequest(
            executablePath: payload.manifest.configuration.executablePath,
            arguments: payload.arguments,
            currentDirectory: payload.manifest.configuration.workingDirectory,
            environment: payload.environment
        )
        let ownedProcess: any RunSupervisorOwnedProcess
        do {
            ownedProcess = try launcher.makeProcess(launchRequest)
        } catch {
            do { _ = try spool.appendCritical(.providerLaunchFailed) }
            catch { throw RunSupervisorError.terminalPersistenceFailed }
            throw error
        }
        let terminated = DispatchSemaphore(value: 0)
        let terminationBox = RunSupervisorTerminationBox()
        ownedProcess.setTerminationHandler { termination in
            if terminationBox.setIfEmpty(termination) {
                terminated.signal()
            }
        }
        do {
            try ownedProcess.run()
        } catch {
            do { _ = try spool.appendCritical(.providerLaunchFailed) }
            catch { throw RunSupervisorError.terminalPersistenceFailed }
            throw error
        }
        var providerCompleted = false
        defer {
            if !providerCompleted {
                _ = ownedProcess.terminateImmediately()
                terminated.wait()
                stateLock.lock(); process = nil; stateLock.unlock()
            }
        }
        lifecycleEventLock.lock()
        do {
            reduce(.executionStarted, capabilities: [.cancel])
            _ = try spool.appendCritical(
                .providerStarted,
                payload: .init(providerPID: ownedProcess.processIdentifierDiagnostic)
            )
            stateLock.lock()
            process = ownedProcess
            stateLock.unlock()
            lifecycleEventLock.unlock()
        } catch {
            lifecycleEventLock.unlock()
            throw error
        }
        let outputPersistenceError = RunSupervisorErrorBox()
        let timeoutWatchdog = payload.manifest.supervisionPolicy.map {
            RunSupervisorTimeoutWatchdog(policy: $0)
        }
        timeoutWatchdog?.start { [weak self, weak ownedProcess] reason in
            guard let self, let ownedProcess else { return }
            self.enforceTimeout(reason, process: ownedProcess)
        }
        defer { timeoutWatchdog?.cancel() }
        do {
            try fileSystem.writeDiscovery(
                .init(
                    identity: discovery.identity,
                    manifestSHA256: discovery.manifestSHA256,
                    launchAuthenticator: discovery.launchAuthenticator,
                    capabilitySHA256: discovery.capabilitySHA256,
                    socketName: discovery.socketName,
                    supervisorPIDDiagnostic: getpid(),
                    providerPIDDiagnostic: ownedProcess.processIdentifierDiagnostic,
                    createdAt: discovery.createdAt
                ),
                in: directory
            )
        } catch {
            // The PID is diagnostic only. Provider ownership and recovery are
            // already durable through discovery identity plus spool evidence.
            runSupervisorServiceLogger.warning(
                "Skipping non-authoritative provider PID discovery update: \(String(describing: error), privacy: .public)"
            )
        }
        let outputGroup = DispatchGroup()
        startOutputReader(
            ownedProcess.stdoutFileHandle,
            kind: .standardOutput,
            spool: spool,
            group: outputGroup,
            persistenceError: outputPersistenceError,
            progress: { timeoutWatchdog?.recordProgress() }
        )
        startOutputReader(
            ownedProcess.stderrFileHandle,
            kind: .standardError,
            spool: spool,
            group: outputGroup,
            persistenceError: outputPersistenceError,
            progress: { timeoutWatchdog?.recordProgress() }
        )
        terminated.wait()
        providerCompleted = true
        guard let termination = terminationBox.value else {
            throw RunSupervisorError.terminalPersistenceFailed
        }
        outputGroup.wait()
        lifecycleEventLock.lock()
        do {
            try recordTermination(termination, spool: spool)
            lifecycleEventLock.unlock()
        } catch {
            lifecycleEventLock.unlock()
            throw error
        }
        server.stop()
        if let error = outputPersistenceError.value { throw error }
        return .launched(exitCode: termination.exitCode)
    }

    private func handle(_ action: RunSupervisorControlAction) throws -> RunSupervisorControlResponse {
        stateLock.lock(); let spool = self.spool; stateLock.unlock()
        guard let spool else { throw RunSupervisorError.alreadyRunningOrInDoubt }
        switch action.kind {
        case .handshake, .status:
            break
        case .replay:
            // One maximum-sized output event plus the authenticated envelope
            // remains below the bounded 64 KiB control frame. Returning four
            // would double-base64-expand the envelope beyond that limit.
            let events = try spool.replay(after: action.afterSequence!, limit: 1)
            return .init(accepted: true, events: events, lastSequence: spool.lastSequence)
        case .acknowledge:
            try spool.acknowledge(through: action.acknowledgeThrough!)
        case .writeStandardInput:
            stateLock.lock(); let process = self.process; stateLock.unlock()
            guard let process else { throw RunSupervisorError.alreadyRunningOrInDoubt }
            try process.writeStandardInputLine(action.standardInputLine!)
            lifecycleEventLock.lock()
            defer { lifecycleEventLock.unlock() }
            stateLock.lock(); let currentProcess = self.process; stateLock.unlock()
            guard let currentProcess,
                  (currentProcess as AnyObject) === (process as AnyObject) else {
                throw RunSupervisorError.alreadyRunningOrInDoubt
            }
            _ = try spool.appendCritical(.standardInputAccepted)
        case .closeStandardInput:
            lifecycleEventLock.lock()
            defer { lifecycleEventLock.unlock() }
            stateLock.lock(); let process = self.process; stateLock.unlock()
            guard let process else { throw RunSupervisorError.alreadyRunningOrInDoubt }
            guard try process.closeStandardInput() else {
                throw RunSupervisorError.alreadyRunningOrInDoubt
            }
            _ = try spool.appendCritical(.standardInputClosed)
        case .cancel:
            try requestCancellation(action.cancellationIntent!, spool: spool)
        }
        return .init(accepted: true, lastSequence: spool.lastSequence)
    }

    private func requestCancellation(
        _ intent: ExecutionCancellationIntent,
        spool: RunSupervisorEventSpool
    ) throws {
        lifecycleEventLock.lock()
        defer { lifecycleEventLock.unlock() }
        stateLock.lock(); let process = self.process; stateLock.unlock()
        guard let process else { throw RunSupervisorError.alreadyRunningOrInDoubt }
        _ = try spool.appendCritical(.cancellationRequested, payload: .init(cancellationIntent: intent))
        if intent == .graceful {
            let supported = process.requestGracefulCancellation()
            reduce(.requestCancellation(intent), capabilities: supported ? [.cancel] : [])
            if supported {
                reduce(.backendAcceptedCancellation, capabilities: [.cancel])
            } else {
                _ = try spool.appendCritical(.cancellationUnsupported, payload: .init(cancellationIntent: intent))
            }
            return
        }
        reduce(.requestCancellation(intent), capabilities: [.cancel])
        reduce(.backendAcceptedCancellation, capabilities: [.cancel])
        // The termination callback may run synchronously. It only stages the
        // raw result; terminal persistence waits for this serialized section
        // to publish whether the signal was actually issued.
        let issued = process.terminateImmediately()
        guard issued else {
            reduce(.observationBecameIndeterminate, capabilities: [.cancel])
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        stateLock.lock(); immediateTerminationIssued = true; stateLock.unlock()
        reduce(.terminationStarted, capabilities: [.cancel])
        _ = try spool.appendCritical(.terminationStarted, payload: .init(cancellationIntent: intent))
    }

    private func recordTermination(
        _ termination: RunSupervisorProcessTermination,
        spool: RunSupervisorEventSpool
    ) throws {
        defer {
            stateLock.lock(); process = nil; stateLock.unlock()
        }
        stateLock.lock()
        let requestedCancellation = controlState.desiredCancellation
        let terminationWasIssued = immediateTerminationIssued
        stateLock.unlock()
        let authoritativelyCancelled = requestedCancellation == .immediate
            && terminationWasIssued
            && termination.signal != nil
        do {
            if authoritativelyCancelled {
                reduce(.cancellationConfirmed, capabilities: [.cancel])
                _ = try spool.appendCritical(
                    .cancellationConfirmed,
                    payload: .init(cancellationIntent: .immediate)
                )
            } else if termination.exitCode == 0 {
                reduce(.executionCompleted, capabilities: [.cancel])
            } else {
                reduce(.executionFailed, capabilities: [.cancel])
            }
            _ = try spool.appendCritical(
                .providerExited,
                payload: .init(
                    exitCode: termination.exitCode,
                    terminationSignal: termination.signal,
                    terminationReason: termination.reason
                )
            )
        } catch {
            throw RunSupervisorError.terminalPersistenceFailed
        }
    }

    private func enforceTimeout(
        _ reason: RunSupervisorTimeoutWatchdog.Reason,
        process timedProcess: any RunSupervisorOwnedProcess
    ) {
        lifecycleEventLock.lock()
        defer { lifecycleEventLock.unlock() }
        stateLock.lock(); let currentProcess = process; stateLock.unlock()
        guard let currentProcess,
              (currentProcess as AnyObject) === (timedProcess as AnyObject) else { return }
        runSupervisorServiceLogger.warning(
            "Provider supervision timeout exceeded: \(reason.rawValue, privacy: .public)"
        )
        _ = timedProcess.terminateImmediately()
    }

    private func reduce(
        _ event: ExecutionControlEvent,
        capabilities: ExternalOperationBackendCapabilities
    ) {
        stateLock.lock()
        controlState = ExecutionControlReducer.reduce(
            controlState,
            event: event,
            backendCapabilities: capabilities
        ).state
        stateLock.unlock()
    }

    private func startOutputReader(
        _ handle: FileHandle,
        kind: RunSupervisorEventKind,
        spool: RunSupervisorEventSpool,
        group: DispatchGroup,
        persistenceError: RunSupervisorErrorBox,
        progress: @escaping @Sendable () -> Void
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { group.leave() }
            guard let self else {
                persistenceError.set(RunSupervisorError.outputPersistenceFailed)
                return
            }
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    persistenceError.set(RunSupervisorError.outputPersistenceFailed)
                    self.stateLock.lock(); let process = self.process; self.stateLock.unlock()
                    _ = process?.terminateImmediately()
                    return
                }
                if count == 0 { return }
                let data = Data(buffer.prefix(count))
                while true {
                    do {
                        _ = try spool.appendOutput(kind, data: data)
                        progress()
                        break
                    } catch RunSupervisorError.spoolBackpressured {
                        _ = spool.waitForOutputCapacity(deadline: self.clock.now().addingTimeInterval(1))
                    } catch {
                        persistenceError.set(RunSupervisorError.outputPersistenceFailed)
                        self.stateLock.lock(); let process = self.process; self.stateLock.unlock()
                        _ = process?.terminateImmediately()
                        return
                    }
                }
            }
        }
    }
}

private final class RunSupervisorTerminationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var termination: RunSupervisorProcessTermination?

    var value: RunSupervisorProcessTermination? {
        lock.lock(); defer { lock.unlock() }
        return termination
    }

    @discardableResult
    func setIfEmpty(_ value: RunSupervisorProcessTermination) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard termination == nil else { return false }
        termination = value
        return true
    }
}

private final class RunSupervisorTimeoutWatchdog: @unchecked Sendable {
    enum Reason: String, Sendable {
        case hard = "hard_timeout"
        case idle = "idle_progress_timeout"
    }

    private let policy: ExecutionSupervisionPolicySnapshot
    private let queue = DispatchQueue(label: "com.coral.ASTRA.run-supervisor-timeout")
    private var hardTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var fired = false

    init(policy: ExecutionSupervisionPolicySnapshot) {
        self.policy = policy
    }

    func start(_ handler: @escaping @Sendable (Reason) -> Void) {
        queue.sync {
            guard hardTimer == nil, idleTimer == nil else { return }
            let hard = DispatchSource.makeTimerSource(queue: queue)
            hard.schedule(deadline: .now() + TimeInterval(policy.hardTimeoutSeconds))
            hard.setEventHandler { [weak self] in self?.fire(.hard, handler: handler) }
            hardTimer = hard

            let idle = DispatchSource.makeTimerSource(queue: queue)
            idle.schedule(deadline: .now() + TimeInterval(policy.idleProgressTimeoutSeconds))
            idle.setEventHandler { [weak self] in self?.fire(.idle, handler: handler) }
            idleTimer = idle
            hard.resume()
            idle.resume()
        }
    }

    func recordProgress() {
        queue.async { [weak self] in
            guard let self, !fired else { return }
            idleTimer?.schedule(
                deadline: .now() + TimeInterval(policy.idleProgressTimeoutSeconds)
            )
        }
    }

    func cancel() {
        queue.sync {
            hardTimer?.cancel()
            idleTimer?.cancel()
            hardTimer = nil
            idleTimer = nil
        }
    }

    private func fire(_ reason: Reason, handler: @escaping @Sendable (Reason) -> Void) {
        guard !fired else { return }
        fired = true
        hardTimer?.cancel()
        idleTimer?.cancel()
        handler(reason)
    }
}

private final class RunSupervisorErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
}
