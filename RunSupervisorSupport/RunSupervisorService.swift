import ASTRACore
import Darwin
import Foundation

public struct RunSupervisorProviderLaunchRequest: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let currentDirectory: String
    public let environment: [String: String]

    public init(
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
    }
}

public protocol RunSupervisorOwnedProcess: AnyObject, Sendable {
    var stdoutFileHandle: FileHandle { get }
    var stderrFileHandle: FileHandle { get }
    var processIdentifierDiagnostic: Int32? { get }
    func setTerminationHandler(_ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void)
    func run() throws
    func writeStandardInputLine(_ line: String) throws
    @discardableResult func closeStandardInput() throws -> Bool
    func requestGracefulCancellation() -> Bool
    @discardableResult func terminateImmediately() -> Bool
}

public struct RunSupervisorProcessTermination: Equatable, Sendable {
    public let exitCode: Int32
    public let signal: Int32?
    public let reason: RunSupervisorTerminationReason

    public init(
        exitCode: Int32,
        signal: Int32?,
        reason: RunSupervisorTerminationReason? = nil
    ) {
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason ?? (signal == nil ? (exitCode < 0 ? .waitFailed : .exited) : .signaled)
    }
}

public protocol RunSupervisorProviderLaunching: Sendable {
    func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess
}

public struct DarwinRunSupervisorProviderLauncher: RunSupervisorProviderLaunching {
    public init() {}

    public func makeProcess(_ request: RunSupervisorProviderLaunchRequest) throws -> any RunSupervisorOwnedProcess {
        DarwinRunSupervisorOwnedProcess(
            process: ExecutionScopedProcess(
                executablePath: request.executablePath,
                arguments: request.arguments,
                currentDirectory: request.currentDirectory,
                environment: request.environment,
                providesStdinChannel: true
            )
        )
    }
}

public final class DarwinRunSupervisorOwnedProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let process: ExecutionScopedProcess
    public init(process: ExecutionScopedProcess) { self.process = process }
    public var stdoutFileHandle: FileHandle { process.stdoutFileHandle }
    public var stderrFileHandle: FileHandle { process.stderrFileHandle }
    public var processIdentifierDiagnostic: Int32? { process.processIdentifierDiagnostic }
    public func setTerminationHandler(
        _ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void
    ) {
        process.terminationHandler = {
            handler(.init(exitCode: $0.terminationStatus, signal: $0.terminationSignalDiagnostic))
        }
    }
    public func run() throws { try process.run() }
    public func writeStandardInputLine(_ line: String) throws { try process.writeStdinLineChecked(line) }
    public func closeStandardInput() throws -> Bool { try process.closeStdinChannelChecked() }
    public func requestGracefulCancellation() -> Bool { false }
    public func terminateImmediately() -> Bool { process.terminateImmediately() }
}

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
            maximumBytes: spoolMaximumBytes,
            criticalReserveBytes: spoolCriticalReserveBytes,
            clock: clock
        )
        self.spool = spool
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
        var shouldStopServer = true
        defer {
            if shouldStopServer { server.stop() }
        }

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
        stateLock.lock()
        process = ownedProcess
        stateLock.unlock()
        let terminated = DispatchSemaphore(value: 0)
        let exitStatus = RunSupervisorExitStatusBox()
        let terminalPersistenceError = RunSupervisorErrorBox()
        ownedProcess.setTerminationHandler { [weak self] termination in
            exitStatus.set(termination.exitCode)
            do {
                try self?.recordTermination(termination)
            } catch {
                terminalPersistenceError.set(error)
            }
            terminated.signal()
        }
        do {
            try ownedProcess.run()
        } catch {
            do { _ = try spool.appendCritical(.providerLaunchFailed) }
            catch { throw RunSupervisorError.terminalPersistenceFailed }
            stateLock.lock(); process = nil; stateLock.unlock()
            throw error
        }
        var providerCompleted = false
        defer {
            if !providerCompleted {
                _ = ownedProcess.terminateImmediately()
                terminated.wait()
            }
        }
        reduce(.executionStarted, capabilities: [.cancel])
        _ = try spool.appendCritical(
            .providerStarted,
            payload: .init(providerPID: ownedProcess.processIdentifierDiagnostic)
        )
        let outputPersistenceError = RunSupervisorErrorBox()
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
        let outputGroup = DispatchGroup()
        startOutputReader(
            ownedProcess.stdoutFileHandle,
            kind: .standardOutput,
            group: outputGroup,
            persistenceError: outputPersistenceError
        )
        startOutputReader(
            ownedProcess.stderrFileHandle,
            kind: .standardError,
            group: outputGroup,
            persistenceError: outputPersistenceError
        )
        terminated.wait()
        providerCompleted = true
        outputGroup.wait()
        server.stop()
        shouldStopServer = false
        if let error = terminalPersistenceError.value { throw error }
        if let error = outputPersistenceError.value { throw error }
        return .launched(exitCode: exitStatus.value)
    }

    private func handle(_ action: RunSupervisorControlAction) throws -> RunSupervisorControlResponse {
        guard let spool else { throw RunSupervisorError.alreadyRunningOrInDoubt }
        switch action.kind {
        case .handshake, .status:
            break
        case .replay:
            let events = try spool.replay(after: action.afterSequence!, limit: 4)
            return .init(accepted: true, events: events, lastSequence: spool.lastSequence)
        case .acknowledge:
            try spool.acknowledge(through: action.acknowledgeThrough!)
        case .writeStandardInput:
            stateLock.lock(); let process = self.process; stateLock.unlock()
            guard let process else { throw RunSupervisorError.alreadyRunningOrInDoubt }
            try process.writeStandardInputLine(action.standardInputLine!)
            _ = try spool.appendCritical(.standardInputAccepted)
        case .closeStandardInput:
            stateLock.lock(); let process = self.process; stateLock.unlock()
            guard let process else { throw RunSupervisorError.alreadyRunningOrInDoubt }
            guard try process.closeStandardInput() else {
                throw RunSupervisorError.alreadyRunningOrInDoubt
            }
            _ = try spool.appendCritical(.standardInputClosed)
        case .cancel:
            try requestCancellation(action.cancellationIntent!)
        }
        return .init(accepted: true, lastSequence: spool.lastSequence)
    }

    private func requestCancellation(_ intent: ExecutionCancellationIntent) throws {
        guard let spool else { throw RunSupervisorError.alreadyRunningOrInDoubt }
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
        let issued = process.terminateImmediately()
        guard issued else {
            reduce(.observationBecameIndeterminate, capabilities: [.cancel])
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        stateLock.lock(); immediateTerminationIssued = true; stateLock.unlock()
        reduce(.terminationStarted, capabilities: [.cancel])
        _ = try spool.appendCritical(.terminationStarted, payload: .init(cancellationIntent: intent))
    }

    private func recordTermination(_ termination: RunSupervisorProcessTermination) throws {
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
        guard let spool else { throw RunSupervisorError.terminalPersistenceFailed }
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
        group: DispatchGroup,
        persistenceError: RunSupervisorErrorBox
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { group.leave() }
            guard let self, let spool = self.spool else {
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

private final class RunSupervisorExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = -1

    var value: Int32 {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func set(_ value: Int32) {
        lock.lock(); status = value; lock.unlock()
    }
}

private final class RunSupervisorErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
}
