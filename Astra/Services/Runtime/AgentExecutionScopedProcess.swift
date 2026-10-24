import Darwin
import Foundation
import ASTRACore

struct AgentExecutionScopedProcessError: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

enum AgentExecutionScopedProcessStdinMode {
    case inherited
    case closed
    case pipe
}

/// Launches a provider in its own process group so cancellation can clean up
/// tool subprocesses that the provider starts or backgrounds.
final class AgentExecutionScopedProcess: @unchecked Sendable, AgentRuntimeProcessControl {
    private let executablePath: String
    private let arguments: [String]
    private let currentDirectory: String
    private let environment: [String: String]
    private let stdinMode: AgentExecutionScopedProcessStdinMode
    private let lock = NSLock()

    private var processID: pid_t = 0
    private var processGroupID: pid_t = 0
    private var running = false
    private var reaped = false
    private var reapedSuccessfully = false
    private var launchIdentity: RuntimeProcessIdentity?
    private var stopRequested = false
    private var status: Int32 = 0

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    // Created only when the provider speaks a stdin control protocol; other
    // providers keep inheriting the parent's stdin unchanged. Writes and the
    // close run on different threads (approval tasks vs the stdout handler
    // closing on `.result`), so handle operations serialize under their own
    // lock — separate from `lock` so a large stdin write can't stall
    // process-state reads like isRunning/terminate.
    private let stdinPipe: Pipe?
    private let stdinLock = NSLock()
    private var stdinClosed = false
    var terminationHandler: ((AgentExecutionScopedProcess) -> Void)?

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    var processIdentifier: Int32 { lock.withLock { processID } }
    var executionIdentity: RuntimeProcessIdentity? { lock.withLock { launchIdentity } }

    func stopProof(executionID: UUID, toolsStopped: Bool, remoteWorkExcluded: Bool) -> RuntimeExecutionStopProof? {
        lock.withLock {
            guard let identity = launchIdentity else { return nil }
            let empty = processGroupID > 0 && kill(-processGroupID, 0) == -1 && errno == ESRCH
            return .init(executionID: executionID, process: identity, reaped: reapedSuccessfully && !running,
                processGroupEmpty: empty, toolsStopped: toolsStopped, remoteWorkExcluded: remoteWorkExcluded, capturedAt: Date())
        }
    }

    init(
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        stdinMode: AgentExecutionScopedProcessStdinMode = .inherited,
        providesStdinChannel: Bool = false
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.stdinMode = providesStdinChannel ? .pipe : stdinMode
        self.stdinPipe = self.stdinMode == .pipe ? Pipe() : nil
    }

    /// Writes one line to the child's stdin. Safe to call after the child has
    /// exited; a broken pipe is swallowed. Serialized with the close so a
    /// write can never race the handle being closed.
    @discardableResult
    func writeStdinLine(_ line: String) -> Bool {
        guard let stdinPipe, let data = (line + "\n").data(using: .utf8) else { return false }
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard !stdinClosed else { return false }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch { return false }
    }

    /// Signals end-of-conversation: stream-json providers keep waiting for the
    /// next stdin message after a turn, so EOF is what lets them exit. Returns
    /// true only when this call closed a live channel — false when there is no
    /// pipe, or when it was already closed and the provider has had its EOF.
    @discardableResult
    func closeStdinChannel() -> Bool {
        guard let stdinPipe else { return false }
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard !stdinClosed else { return false }
        stdinClosed = true
        stdinPipe.fileHandleForWriting.closeFile()
        return true
    }

    func run() throws {
        var spawned = false
        defer {
            if !spawned {
                // No reaper will run after a launch failure. Release the
                // caller's callbacks here, including captures of this process.
                stdoutFileHandle.readabilityHandler = nil
                stderrFileHandle.readabilityHandler = nil
                terminationHandler = nil
            }
        }
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        var childPID = pid_t(0)

        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AgentExecutionScopedProcessError(operation: "posix_spawn_file_actions_init", code: errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        guard posix_spawnattr_init(&attr) == 0 else {
            throw AgentExecutionScopedProcessError(operation: "posix_spawnattr_init", code: errno)
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
            throw AgentExecutionScopedProcessError(operation: "posix_spawnattr_setflags", code: errno)
        }

        var argv = makeCStringArray([executablePath] + arguments)
        var envp = makeCStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        let spawnResult = executablePath.withCString { executable in
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
        spawned = true

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        stdinPipe?.fileHandleForReading.closeFile()

        lock.lock()
        processID = childPID
        processGroupID = childPID
        launchIdentity = RuntimeProcessIdentity.read(childPID)
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapProcess(pid: childPID)
        }
    }

    /// Closes stdin so a stream-json provider sees EOF and can wind its turn
    /// down on its own terms, and says whether there was anything to close. The
    /// watchdog waits on the answer only when there was: a provider with no
    /// stdin pipe cannot notice an EOF it was never sent.
    @discardableResult
    func requestGracefulStop() -> Bool {
        lock.withLock { stopRequested = true }
        return closeStdinChannel()
    }

    /// Only our unreaped child can be resumed. The reaper and signal share the
    /// lock, so PID reuse cannot turn a late recovery into a signal to another
    /// process. No group signal, new process, prompt replay or tool retry occurs.
    var suspendedProcessIdentifier: Int32? {
        lock.withLock { isSuspendedChild() ? processID : nil }
    }

    func resumeSuspendedProcess(expectedPID: Int32) -> Bool {
        lock.withLock {
            guard processID == expectedPID, isSuspendedChild() else { return false }
            return kill(processID, SIGCONT) == 0
        }
    }

    private func isSuspendedChild() -> Bool {
        guard running, !reaped, !stopRequested, processID > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_ppid == UInt32(getpid()) && info.pbi_status == UInt32(SSTOP)
    }

    func terminate() {
        lock.withLock { stopRequested = true }
        let ids = currentIDs()
        guard ids.isRunning else { return }

        Self.signal(processGroupID: ids.processGroupID, processID: ids.processID, signal: SIGTERM)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self else { return }
            let latest = self.currentIDs()
            guard latest.isRunning else { return }
            Self.signal(processGroupID: latest.processGroupID, processID: latest.processID, signal: SIGKILL)
        }
    }

    /// Signals the whole process group (guarded against signalling our own
    /// foreground group) so background children the provider spawned can't
    /// outlive it, falling back to the bare pid if no group was recorded.
    private static func signal(processGroupID: pid_t, processID: pid_t, signal: Int32) {
        if processGroupID > 0, processGroupID != getpgrp() {
            ProcessGroupSpawn.signalProcessGroup(processGroupID, signal: signal)
        } else if processID > 0 {
            kill(processID, signal)
        }
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
        // Keep the child waitable until signalling has finished. A blocking
        // waitpid outside the lock could reap and recycle its PID just before
        // a recovery signal. Polling is private to the reaper, never the UI.
        while true {
            lock.lock()
            result = waitpid(pid, &waitStatus, WNOHANG)
            let retry = result == 0 || (result == -1 && errno == EINTR)
            if !retry { reaped = true; reapedSuccessfully = result == pid }
            lock.unlock()
            if !retry { break }
            usleep(50_000)
        }

        let exitStatus: Int32
        if result == pid {
            exitStatus = Self.exitCode(from: waitStatus)
        } else {
            exitStatus = -1
        }

        cleanupResidualProcessGroup()

        closeStdinChannel()

        lock.lock()
        status = exitStatus
        running = false
        lock.unlock()

        // Completion is one-shot. Worker parsers capture this process, so
        // keeping the callback here retains the whole run's output forever.
        let completion = terminationHandler
        terminationHandler = nil
        completion?(self)
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

    private func currentIDs() -> (processID: pid_t, processGroupID: pid_t, isRunning: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (processID, processGroupID, running)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw AgentExecutionScopedProcessError(operation: operation, code: result)
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
