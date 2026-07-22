import Darwin
import Foundation
import ASTRACore
import OSLog

private let executionScopedProcessLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.coral.ASTRA",
    category: "RunSupervisorProcess"
)

public enum ExecutionScopedProcessLogLevel: Sendable {
    case info
    case warning
    case error
}

public struct ExecutionScopedProcessError: LocalizedError {
    let operation: String
    let code: Int32

    public var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

public enum ExecutionScopedProcessStdinMode: Sendable {
    case inherited
    case closed
    case pipe
}

/// Launches a provider in its own process group so cancellation can clean up
/// tool subprocesses that the provider starts or backgrounds.
public final class ExecutionScopedProcess: @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let currentDirectory: String
    private let environment: [String: String]
    private let stdinMode: ExecutionScopedProcessStdinMode
    private let lock = NSLock()
    private let logSink: @Sendable (ExecutionScopedProcessLogLevel, String) -> Void

    private var processID: pid_t = 0
    private var processGroupID: pid_t = 0
    private var running = false
    private var terminationRequested = false
    private var status: Int32 = 0
    private var terminationSignal: Int32?

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    private let ownerLifetimePipe = Pipe()
    // Created only when the provider speaks a stdin control protocol; other
    // providers keep inheriting the parent's stdin unchanged. Writes and the
    // close run on different threads (approval tasks vs the stdout handler
    // closing on `.result`), so handle operations serialize under their own
    // lock — separate from `lock` so a large stdin write can't stall
    // process-state reads like isRunning/terminate.
    private let stdinPipe: Pipe?
    private let stdinLock = NSLock()
    private var stdinClosed = false
    private let ownerLifetimeLock = NSLock()
    private var ownerLifetimeReadClosed = false
    private var ownerLifetimeWriteClosed = false
    private var descriptorSetupFailureCode: Int32?
    public var terminationHandler: ((ExecutionScopedProcess) -> Void)?

    public var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    public var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Diagnostic only. Ownership and discovery must never rely on PID liveness.
    public var processIdentifierDiagnostic: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return processID > 0 ? processID : nil
    }

    public var terminationSignalDiagnostic: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return terminationSignal
    }

    public var ownerLifetimePipeIsClosedForTesting: Bool {
        ownerLifetimeLock.lock()
        defer { ownerLifetimeLock.unlock() }
        return ownerLifetimeReadClosed && ownerLifetimeWriteClosed
    }

    public init(
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        stdinMode: ExecutionScopedProcessStdinMode = .inherited,
        providesStdinChannel: Bool = false,
        logSink: (@Sendable (ExecutionScopedProcessLogLevel, String) -> Void)? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.stdinMode = providesStdinChannel ? .pipe : stdinMode
        self.logSink = logSink ?? { level, message in
            switch level {
            case .info:
                executionScopedProcessLogger.info("\(message, privacy: .public)")
            case .warning:
                executionScopedProcessLogger.warning("\(message, privacy: .public)")
            case .error:
                executionScopedProcessLogger.error("\(message, privacy: .public)")
            }
        }
        self.stdinPipe = self.stdinMode == .pipe ? Pipe() : nil

        // Pipe descriptors are process-global. Without CLOEXEC, an unrelated
        // concurrent spawn can inherit a duplicate of the lifetime write end
        // and prevent the watchdog from observing real owner EOF.
        let descriptors = [
            stdoutPipe.fileHandleForReading.fileDescriptor,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrPipe.fileHandleForReading.fileDescriptor,
            stderrPipe.fileHandleForWriting.fileDescriptor,
            ownerLifetimePipe.fileHandleForReading.fileDescriptor,
            ownerLifetimePipe.fileHandleForWriting.fileDescriptor
        ] + (stdinPipe.map {
            [$0.fileHandleForReading.fileDescriptor, $0.fileHandleForWriting.fileDescriptor]
        } ?? [])
        for descriptor in descriptors {
            if let failure = Self.setCloseOnExec(descriptor), descriptorSetupFailureCode == nil {
                descriptorSetupFailureCode = failure
            }
        }
        if let stdinPipe {
            let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0,
               descriptorSetupFailureCode == nil {
                descriptorSetupFailureCode = errno
            }
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Int32? {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return errno }
        guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else { return errno }
        return nil
    }

    /// Writes one line to the child's stdin. Safe to call after the child has
    /// exited; a broken pipe is swallowed. Serialized with the close so a
    /// write can never race the handle being closed.
    public func writeStdinLine(_ line: String) {
        try? writeStdinLineChecked(line)
    }

    /// Supervisor-facing variant. Success means the complete line was written
    /// to the locally owned provider pipe; closed/broken pipes are surfaced so
    /// callers cannot durably claim an input acceptance that never happened.
    public func writeStdinLineChecked(_ line: String) throws {
        guard let stdinPipe, let data = (line + "\n").data(using: .utf8) else {
            throw ExecutionScopedProcessError(operation: "write provider stdin", code: ENOTSUP)
        }
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard !stdinClosed else {
            throw ExecutionScopedProcessError(operation: "write provider stdin", code: EPIPE)
        }
        let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        let deadline = ContinuousClock.now + .seconds(1)
        var offset = 0
        while offset < data.count {
            if currentIDs().terminationRequested {
                throw ExecutionScopedProcessError(operation: "write provider stdin", code: EPIPE)
            }
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard ContinuousClock.now < deadline else {
                    throw ExecutionScopedProcessError(operation: "write provider stdin", code: ETIMEDOUT)
                }
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = poll(&writable, 1, 25)
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else {
                    throw ExecutionScopedProcessError(operation: "poll provider stdin", code: errno)
                }
                continue
            }
            throw ExecutionScopedProcessError(operation: "write provider stdin", code: EPIPE)
        }
    }

    /// Signals end-of-conversation: stream-json providers keep waiting for the
    /// next stdin message after a turn, so EOF is what lets them exit.
    public func closeStdinChannel() {
        _ = try? closeStdinChannelChecked()
    }

    /// Returns true only for the transition that successfully closed the local
    /// pipe. Repeated closes are errors for evidence-producing callers.
    public func closeStdinChannelChecked() throws -> Bool {
        guard let stdinPipe else {
            throw ExecutionScopedProcessError(operation: "close provider stdin", code: ENOTSUP)
        }
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard !stdinClosed else {
            throw ExecutionScopedProcessError(operation: "close provider stdin", code: EPIPE)
        }
        do {
            try stdinPipe.fileHandleForWriting.close()
            stdinClosed = true
            return true
        } catch {
            throw ExecutionScopedProcessError(operation: "close provider stdin", code: EIO)
        }
    }

    public func run() throws {
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        var childPID = pid_t(0)
        var didLaunch = false
        defer {
            if !didLaunch {
                closeAfterFailedLaunch()
                logSink(.error, "Provider process containment failed before process-group ownership was established; descriptors closed")
            }
        }

        if let descriptorSetupFailureCode {
            throw ExecutionScopedProcessError(
                operation: "fcntl(FD_CLOEXEC)",
                code: descriptorSetupFailureCode
            )
        }
        guard access(executablePath, X_OK) == 0 else {
            throw ExecutionScopedProcessError(operation: "provider executable preflight", code: errno)
        }

        // Reserve a descriptor outside the range providers commonly use. The
        // spawn dup action creates the sole non-CLOEXEC copy in the child.
        let lifetimeDescriptor = fcntl(
            ownerLifetimePipe.fileHandleForReading.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard lifetimeDescriptor >= 0 else {
            throw ExecutionScopedProcessError(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
        }
        defer { close(lifetimeDescriptor) }

        let launchPlan = ProviderLifetimeWatchdog.launchPlan(
            executablePath: executablePath,
            arguments: arguments,
            lifetimeDescriptor: lifetimeDescriptor
        )

        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ExecutionScopedProcessError(operation: "posix_spawn_file_actions_init", code: errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        guard posix_spawnattr_init(&attr) == 0 else {
            throw ExecutionScopedProcessError(operation: "posix_spawnattr_init", code: errno)
        }
        defer { posix_spawnattr_destroy(&attr) }

        try check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                  operation: "posix_spawn_file_actions_adddup2(stdout)")
        try check(posix_spawn_file_actions_adddup2(&actions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
                  operation: "posix_spawn_file_actions_adddup2(stderr)")
        try check(posix_spawn_file_actions_addclose(&actions, stdoutPipe.fileHandleForReading.fileDescriptor),
                  operation: "posix_spawn_file_actions_addclose(stdout_read)")
        try check(posix_spawn_file_actions_addclose(&actions, stderrPipe.fileHandleForReading.fileDescriptor),
                  operation: "posix_spawn_file_actions_addclose(stderr_read)")
        try check(
            posix_spawn_file_actions_adddup2(
                &actions,
                ownerLifetimePipe.fileHandleForReading.fileDescriptor,
                lifetimeDescriptor
            ),
            operation: "posix_spawn_file_actions_adddup2(owner_lifetime)"
        )
        try check(
            posix_spawn_file_actions_addclose(
                &actions,
                ownerLifetimePipe.fileHandleForReading.fileDescriptor
            ),
            operation: "posix_spawn_file_actions_addclose(owner_lifetime_read)"
        )
        try check(
            posix_spawn_file_actions_addclose(
                &actions,
                ownerLifetimePipe.fileHandleForWriting.fileDescriptor
            ),
            operation: "posix_spawn_file_actions_addclose(owner_lifetime_write)"
        )
        if let stdinPipe {
            try check(posix_spawn_file_actions_adddup2(&actions, stdinPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                      operation: "posix_spawn_file_actions_adddup2(stdin)")
            try check(posix_spawn_file_actions_addclose(&actions, stdinPipe.fileHandleForReading.fileDescriptor),
                      operation: "posix_spawn_file_actions_addclose(stdin_read)")
            try check(posix_spawn_file_actions_addclose(&actions, stdinPipe.fileHandleForWriting.fileDescriptor),
                      operation: "posix_spawn_file_actions_addclose(stdin_write)")
        } else if stdinMode == .closed {
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                      operation: "posix_spawn_file_actions_addopen(stdin)")
        }
        try addWorkingDirectory(to: &actions)

        guard ProcessGroupSpawn.configureNewProcessGroup(&attr) else {
            throw ExecutionScopedProcessError(operation: "posix_spawnattr_setflags", code: errno)
        }

        var argv = makeCStringArray([launchPlan.executablePath] + launchPlan.arguments)
        var envp = makeCStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        let spawnResult = launchPlan.executablePath.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &childPID,
                        executable,
                        &actions,
                        &attr,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
        }
        try check(spawnResult, operation: "posix_spawn")
        didLaunch = true

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        stdinPipe?.fileHandleForReading.closeFile()
        closeOwnerLifetimeRead()

        lock.lock()
        processID = childPID
        processGroupID = childPID
        running = true
        terminationRequested = false
        lock.unlock()

        logSink(.info, "Provider process containment armed for process group \(childPID)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapProcess(pid: childPID)
        }
    }

    public func terminate() {
        _ = terminateImmediately()
    }

    @discardableResult
    public func terminateImmediately() -> Bool {
        let ids = currentIDs()
        guard ids.isRunning else { return false }

        let issued = Self.signal(
            processGroupID: ids.processGroupID,
            processID: ids.processID,
            signal: SIGTERM
        )
        if issued {
            lock.lock()
            terminationRequested = true
            lock.unlock()
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self else { return }
            let latest = self.currentIDs()
            guard latest.isRunning else { return }
            _ = Self.signal(processGroupID: latest.processGroupID, processID: latest.processID, signal: SIGKILL)
        }
        return issued
    }

    /// Signals the whole process group (guarded against signalling our own
    /// foreground group) so background children the provider spawned can't
    /// outlive it, falling back to the bare pid if no group was recorded.
    private static func signal(processGroupID: pid_t, processID: pid_t, signal: Int32) -> Bool {
        if processGroupID > 0, processGroupID != getpgrp() {
            return kill(-processGroupID, signal) == 0
        } else if processID > 0 {
            return kill(processID, signal) == 0
        }
        return false
    }

    private func addWorkingDirectory(to actions: inout posix_spawn_file_actions_t?) throws {
        let result = currentDirectory.withCString { path in
            if #available(macOS 26.0, *) {
                return posix_spawn_file_actions_addchdir(&actions, path)
            } else {
                return posix_spawn_file_actions_addchdir_np(&actions, path)
            }
        }
        try check(result, operation: "posix_spawn_file_actions_addchdir")
    }

    private func reapProcess(pid: pid_t) {
        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &waitStatus, 0)
        } while result == -1 && errno == EINTR

        let exitStatus: Int32
        if result == pid {
            exitStatus = Self.exitCode(from: waitStatus)
        } else {
            exitStatus = -1
            logSink(
                .warning,
                "Provider process wait failed for process group \(pid): \(String(cString: strerror(errno)))"
            )
        }

        cleanupResidualProcessGroup()
        closeOwnerLifetimeWrite()

        closeStdinChannel()

        lock.lock()
        status = exitStatus
        let signal = waitStatus & 0x7f
        terminationSignal = result == pid && signal != 0 ? signal : nil
        running = false
        lock.unlock()

        logSink(
            .info,
            "Provider process containment released for process group \(pid) with status \(exitStatus)"
        )

        terminationHandler?(self)
    }

    private func closeAfterFailedLaunch() {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        stdinPipe?.fileHandleForReading.closeFile()
        closeOwnerLifetimeRead()
        closeOwnerLifetimeWrite()
        closeStdinChannel()
    }

    private func closeOwnerLifetimeRead() {
        ownerLifetimeLock.lock()
        defer { ownerLifetimeLock.unlock() }
        guard !ownerLifetimeReadClosed else { return }
        ownerLifetimeReadClosed = true
        ownerLifetimePipe.fileHandleForReading.closeFile()
    }

    private func closeOwnerLifetimeWrite() {
        ownerLifetimeLock.lock()
        defer { ownerLifetimeLock.unlock() }
        guard !ownerLifetimeWriteClosed else { return }
        ownerLifetimeWriteClosed = true
        ownerLifetimePipe.fileHandleForWriting.closeFile()
    }

    private func cleanupResidualProcessGroup() {
        let ids = currentIDs()
        guard ids.processGroupID > 0, ids.processGroupID != getpgrp() else {
            return
        }

        if kill(-ids.processGroupID, SIGTERM) == 0 {
            usleep(200_000)
        }
        ProcessGroupSpawn.signalProcessGroup(ids.processGroupID, signal: SIGKILL)
    }

    private func currentIDs() -> (
        processID: pid_t,
        processGroupID: pid_t,
        isRunning: Bool,
        terminationRequested: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (processID, processGroupID, running, terminationRequested)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ExecutionScopedProcessError(operation: operation, code: result)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array {
            if let pointer {
                free(pointer)
            }
        }
    }
}
