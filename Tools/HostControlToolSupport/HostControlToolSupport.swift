import Darwin
import Foundation
import MCPServerKit

public struct HostControlToolConfiguration: Equatable, Sendable {
    public static let knownToolNames: Set<String> = ["github", "gcloud", "bq", "ssh", "jira", "redcap"]

    public var githubExecutable: String
    public var gcloudExecutable: String
    public var bigQueryExecutable: String
    public var sshExecutable: String
    public var allowedSSHAliases: [String]
    public var allowedTools: Set<String>
    public var currentDirectory: String
    /// Where a brokered tool writes output it must not return inline. Falls
    /// back to `currentDirectory` when the app did not project one.
    public var taskFolder: String
    public var diagnosticsHostPath: String
    public var taskID: String
    public var runID: String
    public var connectorsJSON: String
    public var environment: [String: String]

    public init(
        githubExecutable: String = "gh",
        gcloudExecutable: String = "gcloud",
        bigQueryExecutable: String = "bq",
        sshExecutable: String = "ssh",
        allowedSSHAliases: [String] = [],
        allowedTools: Set<String> = knownToolNames,
        currentDirectory: String = "",
        taskFolder: String = "",
        diagnosticsHostPath: String = "",
        taskID: String = "unknown-task",
        runID: String = "unknown-run",
        connectorsJSON: String = #"{"connectors":[]}"#,
        environment: [String: String] = [:]
    ) {
        self.githubExecutable = Self.clean(githubExecutable) ?? "gh"
        self.gcloudExecutable = Self.clean(gcloudExecutable) ?? "gcloud"
        self.bigQueryExecutable = Self.clean(bigQueryExecutable) ?? "bq"
        self.sshExecutable = Self.clean(sshExecutable) ?? "ssh"
        self.allowedSSHAliases = Self.deduplicated(allowedSSHAliases.compactMap(Self.clean))
        let normalizedTools = Set(allowedTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .intersection(Self.knownToolNames)
        self.allowedTools = normalizedTools
        self.currentDirectory = Self.clean(currentDirectory) ?? ""
        self.taskFolder = Self.clean(taskFolder) ?? ""
        self.diagnosticsHostPath = Self.clean(diagnosticsHostPath) ?? ""
        self.taskID = Self.clean(taskID) ?? "unknown-task"
        self.runID = Self.clean(runID) ?? "unknown-run"
        self.connectorsJSON = Self.clean(connectorsJSON) ?? #"{"connectors":[]}"#
        self.environment = environment
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HostControlToolConfiguration {
        HostControlToolConfiguration(
            githubExecutable: clean(env["ASTRA_HOST_CONTROL_GH_EXECUTABLE"]) ?? "gh",
            gcloudExecutable: clean(env["ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE"]) ?? "gcloud",
            bigQueryExecutable: clean(env["ASTRA_HOST_CONTROL_BQ_EXECUTABLE"]) ?? "bq",
            sshExecutable: clean(env["ASTRA_HOST_CONTROL_SSH_EXECUTABLE"]) ?? "ssh",
            allowedSSHAliases: splitList(env["ASTRA_HOST_CONTROL_ALLOWED_SSH_ALIASES"]),
            allowedTools: allowedToolSet(env["ASTRA_HOST_CONTROL_ALLOWED_TOOLS"]),
            currentDirectory: clean(env["ASTRA_HOST_CONTROL_CURRENT_DIRECTORY"]) ?? "",
            taskFolder: clean(env["ASTRA_HOST_CONTROL_TASK_FOLDER"]) ?? "",
            diagnosticsHostPath: clean(env["ASTRA_HOST_CONTROL_DIAGNOSTICS_HOST"]) ?? "",
            taskID: clean(env["ASTRA_HOST_CONTROL_TASK_ID"]) ?? "unknown-task",
            runID: clean(env["ASTRA_HOST_CONTROL_RUN_ID"]) ?? "unknown-run",
            connectorsJSON: clean(env["ASTRA_CONNECTORS"]) ?? #"{"connectors":[]}"#,
            environment: env
        )
    }

    public var connectorManifest: HostControlConnectorManifest {
        (try? JSONDecoder().decode(HostControlConnectorManifest.self, from: Data(connectorsJSON.utf8)))
            ?? HostControlConnectorManifest(connectors: [])
    }

    private static func splitList(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map(String.init)
            .compactMap(clean)
    }

    private static func allowedToolSet(_ value: String?) -> Set<String> {
        guard value != nil else { return knownToolNames }
        return Set(splitList(value).map { $0.lowercased() }).intersection(knownToolNames)
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct HostControlConnectorManifest: Codable, Equatable, Sendable {
    public var connectors: [HostControlConnector]

    public init(connectors: [HostControlConnector]) {
        self.connectors = connectors
    }
}

public struct HostControlConnector: Codable, Equatable, Sendable {
    public var id: String
    public var alias: String
    public var envPrefix: String
    public var name: String
    public var serviceType: String
    public var baseURL: String
    public var authMethod: String
    public var env: [String: String]
    public var credentials: [String: String]
    public var config: [String: String]
}

public struct HostControlCommandResult: Equatable, Sendable {
    public var command: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        command: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public struct HostControlProcessLimits: Equatable, Sendable {
    public static let standard = HostControlProcessLimits()
    private static let defaultMaximumTimeoutSeconds: TimeInterval = 300
    private static let maximumConfigurableTimeoutSeconds: TimeInterval = 24 * 60 * 60

    public let maximumTimeoutSeconds: TimeInterval
    public let outputByteLimit: Int

    public init(
        maximumTimeoutSeconds: TimeInterval = 300,
        outputByteLimit: Int = 256 * 1024
    ) {
        let finiteMaximum = maximumTimeoutSeconds.isFinite ? maximumTimeoutSeconds : Self.defaultMaximumTimeoutSeconds
        self.maximumTimeoutSeconds = min(max(1, finiteMaximum), Self.maximumConfigurableTimeoutSeconds)
        self.outputByteLimit = max(1, outputByteLimit)
    }

    func clampedTimeout(_ requested: TimeInterval) -> TimeInterval {
        let finiteRequest = requested.isFinite ? requested : maximumTimeoutSeconds
        return min(max(1, finiteRequest), maximumTimeoutSeconds)
    }
}

struct HostControlCappedOutput: Equatable {
    var value: String
    var truncated: Bool
}

enum HostControlOutputCap {
    static func capped(_ value: String, label: String, byteLimit: Int) -> HostControlCappedOutput {
        guard value.utf8.count > byteLimit else {
            return HostControlCappedOutput(value: value, truncated: false)
        }

        let marker = "\n[ASTRA \(label) output capped after \(byteLimit) bytes]\n"
        let markerByteCount = min(byteLimit, marker.utf8.count)
        let prefixByteLimit = max(0, byteLimit - markerByteCount)
        var capped = String()
        capped.reserveCapacity(min(value.count, prefixByteLimit))
        var usedBytes = 0

        for scalar in value.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            guard usedBytes + scalarByteCount <= prefixByteLimit else { break }
            capped.unicodeScalars.append(scalar)
            usedBytes += scalarByteCount
        }

        let remainingBytes = max(0, byteLimit - capped.utf8.count)
        capped += String(decoding: marker.utf8.prefix(remainingBytes), as: UTF8.self)
        return HostControlCappedOutput(value: capped, truncated: true)
    }
}

public protocol HostControlProcessRunning: AnyObject {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String],
        currentDirectory: String?
    ) -> HostControlCommandResult
}
private struct HostControlScopedProcessError: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

private final class HostControlScopedProcess: @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectory: String?
    private let lock = NSLock()

    private var processID: pid_t = 0
    private var processGroupID: pid_t = 0
    private var running = false
    private var status: Int32 = 0

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    private let parentLifetimePipe = Pipe()
    var terminationHandler: ((HostControlScopedProcess) -> Void)?

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

    init(executablePath: String, arguments: [String], environment: [String: String], currentDirectory: String?) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        let trimmedDirectory = currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.currentDirectory = trimmedDirectory.isEmpty ? nil : trimmedDirectory
        // Close-on-exec as early after creation as Foundation's Pipe API
        // allows: without this, a sibling HostControlProcessRunner.run()
        // call whose own posix_spawn forks while these fds are still open
        // in this process inherits duplicates of them, which keeps this
        // pipe's write end alive - and its read end from ever seeing real
        // EOF - for as long as that unrelated sibling keeps running.
        // `run()`'s posix_spawn_file_actions_adddup2 below creates a fresh,
        // non-CLOEXEC descriptor at the target position, so this has no
        // effect on what our own child inherits.
        Self.setCloseOnExec(stdoutPipe.fileHandleForReading.fileDescriptor)
        Self.setCloseOnExec(stdoutPipe.fileHandleForWriting.fileDescriptor)
        Self.setCloseOnExec(stderrPipe.fileHandleForReading.fileDescriptor)
        Self.setCloseOnExec(stderrPipe.fileHandleForWriting.fileDescriptor)
        Self.setCloseOnExec(parentLifetimePipe.fileHandleForReading.fileDescriptor)
        Self.setCloseOnExec(parentLifetimePipe.fileHandleForWriting.fileDescriptor)
    }

    private static func setCloseOnExec(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }

    func run() throws {
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        var childPID = pid_t(0)
        let lifetimeDescriptor = fcntl(
            parentLifetimePipe.fileHandleForReading.fileDescriptor,
            F_DUPFD_CLOEXEC,
            64
        )
        guard lifetimeDescriptor >= 0 else {
            throw HostControlScopedProcessError(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
        }
        defer { close(lifetimeDescriptor) }

        let launchPlan = HostControlParentDeathSupervisor.launchPlan(
            executablePath: executablePath,
            arguments: arguments,
            lifetimeDescriptor: lifetimeDescriptor
        )

        try check(posix_spawn_file_actions_init(&actions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }

        try check(posix_spawnattr_init(&attr), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attr) }

        try addPipe(stdoutPipe, targetDescriptor: STDOUT_FILENO, actions: &actions, operation: "stdout")
        try addPipe(stderrPipe, targetDescriptor: STDERR_FILENO, actions: &actions, operation: "stderr")
        try check(
            posix_spawn_file_actions_adddup2(
                &actions,
                parentLifetimePipe.fileHandleForReading.fileDescriptor,
                lifetimeDescriptor
            ),
            operation: "posix_spawn_file_actions_adddup2(parent_lifetime)"
        )
        try check(
            posix_spawn_file_actions_addclose(
                &actions,
                parentLifetimePipe.fileHandleForReading.fileDescriptor
            ),
            operation: "posix_spawn_file_actions_addclose(parent_lifetime_read)"
        )
        try check(
            posix_spawn_file_actions_addclose(
                &actions,
                parentLifetimePipe.fileHandleForWriting.fileDescriptor
            ),
            operation: "posix_spawn_file_actions_addclose(parent_lifetime_write)"
        )
        if let currentDirectory {
            try currentDirectory.withCString { path in
                try check(posix_spawn_file_actions_addchdir_np(&actions, path), operation: "posix_spawn_file_actions_addchdir_np")
            }
        }

        try check(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)), operation: "posix_spawnattr_setflags")
        try check(posix_spawnattr_setpgroup(&attr, 0), operation: "posix_spawnattr_setpgroup")

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

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        parentLifetimePipe.fileHandleForReading.closeFile()

        lock.lock()
        processID = childPID
        processGroupID = childPID
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapProcess(pid: childPID)
        }
    }

    func terminate() {
        signal(signal: SIGTERM)
    }

    func kill() {
        signal(signal: SIGKILL)
    }

    private func addPipe(
        _ pipe: Pipe,
        targetDescriptor: Int32,
        actions: inout posix_spawn_file_actions_t?,
        operation: String
    ) throws {
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let writeDescriptor = pipe.fileHandleForWriting.fileDescriptor
        try check(posix_spawn_file_actions_adddup2(&actions, writeDescriptor, targetDescriptor),
                  operation: "posix_spawn_file_actions_adddup2(\(operation))")
        try check(posix_spawn_file_actions_addclose(&actions, readDescriptor),
                  operation: "posix_spawn_file_actions_addclose(\(operation)_read)")
        if writeDescriptor != targetDescriptor {
            try check(posix_spawn_file_actions_addclose(&actions, writeDescriptor),
                      operation: "posix_spawn_file_actions_addclose(\(operation)_write)")
        }
    }

    private func reapProcess(pid: pid_t) {
        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &waitStatus, 0)
        } while result == -1 && errno == EINTR

        let exitStatus: Int32 = result == pid ? Self.exitCode(from: waitStatus) : -1
        cleanupResidualProcessGroup()

        lock.lock()
        status = exitStatus
        running = false
        lock.unlock()

        terminationHandler?(self)
    }

    private func cleanupResidualProcessGroup() {
        let ids = currentIDs()
        guard ids.processGroupID > 0, ids.processGroupID != getpgrp() else { return }

        if Darwin.kill(-ids.processGroupID, SIGTERM) == 0 {
            usleep(200_000)
        }
        Darwin.kill(-ids.processGroupID, SIGKILL)
    }

    private func signal(signal: Int32) {
        let ids = currentIDs()
        guard ids.isRunning else { return }
        if ids.processGroupID > 0, ids.processGroupID != getpgrp() {
            Darwin.kill(-ids.processGroupID, signal)
        }
        if ids.processID > 0 {
            Darwin.kill(ids.processID, signal)
        }
    }

    private func currentIDs() -> (processID: pid_t, processGroupID: pid_t, isRunning: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (processID, processGroupID, running)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw HostControlScopedProcessError(operation: operation, code: result)
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

public final class HostControlProcessRunner: HostControlProcessRunning {
    private let limits: HostControlProcessLimits
    private let cancellationRegistry: HostControlOperationCancellationRegistry?
    private let outputLimitGraceSeconds: TimeInterval = 0.5
    private let timeoutGraceSeconds: TimeInterval = 0.5
    private let drainNoDataGraceSeconds: TimeInterval = 2

    public init(limits: HostControlProcessLimits = .standard) {
        self.limits = limits
        self.cancellationRegistry = nil
    }

    init(
        limits: HostControlProcessLimits,
        cancellationRegistry: HostControlOperationCancellationRegistry
    ) {
        self.limits = limits
        self.cancellationRegistry = cancellationRegistry
    }

    public func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environment: [String: String],
        currentDirectory: String? = nil
    ) -> HostControlCommandResult {
        let invocation = commandInvocation(executablePath: executablePath, arguments: arguments)

        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }

        let process = HostControlScopedProcess(
            executablePath: invocation.executablePath,
            arguments: invocation.arguments,
            environment: processEnvironment,
            currentDirectory: currentDirectory
        )
        let stdoutBuffer = BoundedProcessOutput(label: "stdout", byteLimit: limits.outputByteLimit)
        let stderrBuffer = BoundedProcessOutput(label: "stderr", byteLimit: limits.outputByteLimit)
        let outputLimitExceeded = LockedFlag()
        let stdoutReader = ProcessOutputReadHandle(process.stdoutFileHandle)
        let stderrReader = ProcessOutputReadHandle(process.stderrFileHandle)

        let terminateForOutputLimit: () -> Void = {
            if outputLimitExceeded.setIfUnset() {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
        stdoutReader.setReadabilityHandler { handle in
            guard !stdoutBuffer.isTruncated else { return true }
            let data = handle.availableData
            guard !data.isEmpty else { return true }
            if stdoutBuffer.append(data) {
                terminateForOutputLimit()
                return true
            }
            return false
        }
        stderrReader.setReadabilityHandler { handle in
            guard !stderrBuffer.isTruncated else { return true }
            let data = handle.availableData
            guard !data.isEmpty else { return true }
            if stderrBuffer.append(data) {
                terminateForOutputLimit()
                return true
            }
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            return HostControlCommandResult(
                command: executablePath,
                arguments: arguments,
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let cancelled = LockedFlag()
        let cancellationRegistration = cancellationRegistry?.register {
            _ = cancelled.setIfUnset()
            if process.isRunning {
                process.terminate()
            }
        }
        defer {
            cancellationRegistry?.unregister(cancellationRegistration)
        }
        let waitOutcome = waitForProcess(
            semaphore: semaphore,
            timeoutSeconds: limits.clampedTimeout(timeoutSeconds),
            outputLimitExceeded: outputLimitExceeded,
            cancelled: cancelled
        )
        let timedOut = waitOutcome == .timedOut
        switch waitOutcome {
        case .exited:
            break
        case .outputLimited:
            stopProcess(process, semaphore: semaphore, graceSeconds: outputLimitGraceSeconds)
        case .timedOut:
            stopProcess(process, semaphore: semaphore, graceSeconds: timeoutGraceSeconds)
        case .cancelled:
            stopProcess(process, semaphore: semaphore, graceSeconds: timeoutGraceSeconds)
        }

        drainPipe(stdoutReader, into: stdoutBuffer, onLimitExceeded: terminateForOutputLimit)
        drainPipe(stderrReader, into: stderrBuffer, onLimitExceeded: terminateForOutputLimit)

        let stdoutOutput = stdoutBuffer.cappedStringValue
        let stderrOutput = stderrBuffer.cappedStringValue
        let stdoutTruncated = stdoutBuffer.isTruncated || stdoutOutput.truncated
        let stderrTruncated = stderrBuffer.isTruncated || stderrOutput.truncated
        let outputTruncated = outputLimitExceeded.isSet || stdoutTruncated || stderrTruncated

        return HostControlCommandResult(
            command: executablePath,
            arguments: arguments,
            exitCode: cancelled.isSet ? 130 : timedOut ? 124 : outputTruncated ? 125 : process.terminationStatus,
            stdout: stdoutOutput.value,
            stderr: cancelled.isSet && stderrOutput.value.isEmpty
                ? "Cancelled by ASTRA."
                : stderrOutput.value,
            timedOut: timedOut,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated
        )
    }

    private enum ProcessWaitOutcome {
        case exited
        case outputLimited
        case timedOut
        case cancelled
    }

    private func waitForProcess(
        semaphore: DispatchSemaphore,
        timeoutSeconds: TimeInterval,
        outputLimitExceeded: LockedFlag,
        cancelled: LockedFlag
    ) -> ProcessWaitOutcome {
        let deadline = DispatchTime.now() + dispatchInterval(seconds: timeoutSeconds)
        while true {
            if cancelled.isSet {
                return .cancelled
            }
            if semaphore.wait(timeout: .now() + 0.05) == .success {
                return .exited
            }
            if outputLimitExceeded.isSet {
                return .outputLimited
            }
            if DispatchTime.now() >= deadline {
                return .timedOut
            }
        }
    }

    private func dispatchInterval(seconds: TimeInterval) -> DispatchTimeInterval {
        let milliseconds = max(1, Int((seconds * 1_000).rounded(.up)))
        return .milliseconds(milliseconds)
    }

    private func stopProcess(_ process: HostControlScopedProcess, semaphore: DispatchSemaphore, graceSeconds: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + graceSeconds) == .success {
            return
        }
        if process.isRunning {
            process.kill()
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }

    private func drainPipe(
        _ reader: ProcessOutputReadHandle,
        into buffer: BoundedProcessOutput,
        onLimitExceeded: () -> Void
    ) {
        guard let handle = reader.claimForDrain() else { return }

        guard !buffer.isTruncated else {
            try? handle.close()
            return
        }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            buffer.markTruncated()
            try? handle.close()
            return
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            buffer.markTruncated()
            try? handle.close()
            return
        }

        var bytes = [UInt8](repeating: 0, count: 8192)
        defer { try? handle.close() }
        let noDataDeadline = DispatchTime.now() + dispatchInterval(seconds: drainNoDataGraceSeconds)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // A sibling process spawned around the same time as this
                    // one can briefly hold a fork-inherited duplicate of this
                    // pipe's write end open, which keeps the kernel from
                    // signaling real EOF even after our own child has
                    // exited. That shows up here as EAGAIN, not as an actual
                    // error - wait briefly for either more data or true EOF
                    // instead of giving up and reporting a spurious limit.
                    guard DispatchTime.now() < noDataDeadline else {
                        buffer.markTruncated()
                        return
                    }
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    _ = poll(&pollDescriptor, 1, 20)
                    continue
                }
                buffer.markTruncated()
                return
            }
            let data = Data(bytes.prefix(count))
            if buffer.append(data) {
                onLimitExceeded()
                return
            }
        }
    }

    private func commandInvocation(executablePath: String, arguments: [String]) -> (executablePath: String, arguments: [String]) {
        if executablePath.contains("/") {
            return (executablePath, arguments)
        }
        return ("/usr/bin/env", [executablePath] + arguments)
    }
}

public final class HostControlToolDiagnosticsRecorder: @unchecked Sendable {
    private let diagnosticsDirectory: URL
    private let fileURL: URL
    private let taskID: String
    private let runID: String
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(configuration: HostControlToolConfiguration, fileManager: FileManager = .default) {
        self.diagnosticsDirectory = URL(fileURLWithPath: configuration.diagnosticsHostPath, isDirectory: true)
        self.fileURL = diagnosticsDirectory.appendingPathComponent("host_control_tool_activity.jsonl", isDirectory: false)
        self.taskID = configuration.taskID
        self.runID = configuration.runID
        self.fileManager = fileManager
    }

    func record(toolName: String, summary: String, result: HostControlCommandResult?) {
        let redactedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        write(HostControlDiagnosticRecord(
            timestamp: Self.timestamp(),
            taskID: taskID,
            runID: runID,
            route: "host_control_mcp",
            toolName: toolName,
            summary: redactedSummary.isEmpty ? nil : redactedSummary,
            exitCode: result?.exitCode,
            timedOut: result?.timedOut ?? false,
            stderrTail: Self.tail(result?.stderr ?? "")
        ))
    }

    private func write(_ record: HostControlDiagnosticRecord) {
        guard !diagnosticsDirectory.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics are best-effort and must never block a host-control operation.
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func tail(_ value: String, limit: Int = 2_000) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(limit))
    }
}

private struct HostControlDiagnosticRecord: Codable {
    var timestamp: String
    var taskID: String
    var runID: String
    var route: String
    var toolName: String
    var summary: String?
    var exitCode: Int32?
    var timedOut: Bool
    var stderrTail: String?
}

public final class HostControlMCPServer {
    private let configuration: HostControlToolConfiguration
    private let processRunner: HostControlProcessRunning
    private let cancellationRegistry: HostControlOperationCancellationRegistry
    private let diagnosticsRecorder: HostControlToolDiagnosticsRecorder?
    private let processLimits: HostControlProcessLimits
    private lazy var server = MCPServer(
        name: "astra-host-control",
        tools: { [weak self] in
            self?.toolSchemas() ?? []
        },
        handleToolCall: { [weak self] call in
            self?.handleToolCall(call) ?? .error(code: -32000, message: "Host-control MCP server is unavailable")
        }
    )

    public init(
        configuration: HostControlToolConfiguration,
        processRunner: HostControlProcessRunning? = nil,
        diagnosticsRecorder: HostControlToolDiagnosticsRecorder? = nil,
        processLimits: HostControlProcessLimits = .standard
    ) {
        let cancellationRegistry = HostControlOperationCancellationRegistry()
        self.configuration = configuration
        self.cancellationRegistry = cancellationRegistry
        self.processRunner = processRunner ?? HostControlProcessRunner(
            limits: processLimits,
            cancellationRegistry: cancellationRegistry
        )
        self.diagnosticsRecorder = diagnosticsRecorder
        self.processLimits = processLimits
    }

    public func handleLine(_ line: String) -> String? {
        server.handleLine(line)
    }

    public func cancelActiveOperations() {
        cancellationRegistry.cancelAll()
    }

    private func handleToolCall(_ call: MCPToolCall) -> MCPServerReply {
        let normalizedToolName = normalizedToolName(call.name)
        guard toolIsAllowed(normalizedToolName) else {
            return .error(code: -32602, message: "\(normalizedToolName) is not enabled for this task")
        }
        let arguments = call.arguments
        switch normalizedToolName {
        case "github":
            return handleProcessTool(
                toolName: normalizedToolName,
                executable: configuration.githubExecutable,
                arguments: arguments,
                allowedFirstArguments: nil,
                argumentPolicy: GitHubHostControlPolicy.denialReason(for:)
            )
        case "gcloud":
            return handleProcessTool(
                toolName: normalizedToolName,
                executable: configuration.gcloudExecutable,
                arguments: arguments,
                allowedFirstArguments: nil,
                argumentPolicy: { arguments in
                    if let rejection = GCloudHostControlPolicy.rejectionMessage(arguments: arguments) {
                        return rejection
                    }
                    switch HostControlCloudCommandPolicy.gcloud.evaluate(arguments: arguments) {
                    case .allowed:
                        return nil
                    case .denied(let message):
                        return message
                    }
                }
            )
        case "bq":
            return handleProcessTool(
                toolName: normalizedToolName,
                executable: configuration.bigQueryExecutable,
                arguments: arguments,
                allowedFirstArguments: nil,
                argumentPolicy: BigQueryHostControlPolicy.rejectionMessage
            )
        case "ssh":
            return handleSSH(arguments: arguments)
        case "jira":
            return handleJira(arguments: arguments)
        case "redcap":
            return REDCapHostControlPolicy.handle(
                arguments: arguments,
                configuration: configuration,
                processLimits: processLimits,
                cancellationRegistry: cancellationRegistry,
                diagnostics: diagnosticsRecorder
            )
        default:
            return .error(code: -32602, message: "Unsupported tool")
        }
    }

    private func handleProcessTool(
        toolName: String,
        executable: String,
        arguments: [String: Any],
        allowedFirstArguments: Set<String>?,
        argumentPolicy: (([String]) -> String?)? = nil
    ) -> MCPServerReply {
        guard let argv = stringArray(arguments["arguments"]) else {
            return .error(code: -32602, message: "\(toolName) requires an arguments array")
        }
        guard validateArguments(argv) else {
            return .error(code: -32602, message: "\(toolName) arguments must be non-empty strings without newlines")
        }
        if let allowedFirstArguments,
           let first = argv.first?.lowercased(),
           !allowedFirstArguments.contains(first) {
            return .error(code: -32602, message: "\(toolName) does not allow subcommand '\(first)'")
        }
        if let rejection = argumentPolicy?(argv) {
            let diagnosticArguments = redactedDiagnosticArguments(argv)
            diagnosticsRecorder?.record(
                toolName: toolName,
                summary: "\(toolName) \(diagnosticArguments.joined(separator: " "))",
                result: HostControlCommandResult(
                    command: executable,
                    arguments: diagnosticArguments,
                    exitCode: 126,
                    stdout: "",
                    stderr: rejection,
                    timedOut: false
                )
            )
            return .error(code: -32602, message: rejection)
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
        let result = processRunner.run(
            executablePath: executable,
            arguments: argv,
            timeoutSeconds: timeout,
            environment: configuration.environment,
            currentDirectory: configuration.currentDirectory
        )
        let redacted = redactedResult(result)
        diagnosticsRecorder?.record(
            toolName: toolName,
            summary: "\(toolName) \(argv.joined(separator: " "))",
            result: redacted
        )
        return encodeCommandResult(result: redacted)
    }

    private func handleSSH(arguments: [String: Any]) -> MCPServerReply {
        guard let alias = clean(arguments["alias"] as? String) else {
            return .error(code: -32602, message: "ssh requires alias")
        }
        guard validateArguments([alias]) else {
            return .error(code: -32602, message: "ssh alias must be a single non-empty value without newlines")
        }
        let allowed = Set(configuration.allowedSSHAliases)
        if !allowed.isEmpty, !allowed.contains(alias) {
            return .error(
                code: -32602,
                message: "ssh alias '\(alias)' is not in ASTRA's configured workspace SSH aliases"
            )
        }
        if HostControlSSHCommandPolicy.containsUnsupportedCommandInput(arguments) {
            return .error(code: -32602, message: HostControlSSHCommandPolicy.remoteCommandRejectionMessage)
        }
        let sshArguments = HostControlSSHCommandPolicy.connectionCheckArguments(for: alias)
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
        let result = processRunner.run(
            executablePath: configuration.sshExecutable,
            arguments: sshArguments,
            timeoutSeconds: timeout,
            environment: configuration.environment,
            currentDirectory: configuration.currentDirectory
        )
        let redacted = redactedResult(result)
        diagnosticsRecorder?.record(
            toolName: "ssh",
            summary: "ssh \(sshArguments.joined(separator: " "))",
            result: redacted
        )
        return encodeCommandResult(result: redacted)
    }

    private func handleJira(arguments: [String: Any]) -> MCPServerReply {
        let operation = (clean(arguments["operation"] as? String) ?? "status").lowercased()
        guard let connector = jiraConnector(alias: clean(arguments["alias"] as? String)) else {
            return .error(code: -32602, message: "No Jira connector is projected into ASTRA_CONNECTORS")
        }
        switch operation {
        case "status":
            let status = jiraStatus(connector: connector)
            diagnosticsRecorder?.record(toolName: "jira", summary: "jira status \(connector.alias)", result: nil)
            return .result([
                "content": [[
                    "type": "text",
                    "text": formattedJiraStatus(status)
                ]],
                "isError": !status.ready
            ])
        case "get_issue", "search_jql", "get_comments":
            return handleJiraReadRequest(operation: operation, connector: connector, arguments: arguments)
        case "propose_issue":
            return handleJiraIssueProposal(connector: connector, arguments: arguments)
        default:
            return .error(code: -32602, message: "Unsupported Jira operation '\(operation)'")
        }
    }

    /// Checks the connector can authenticate, then hands off to
    /// `JiraIssueProposalPolicy`, which composes and stages the payload without
    /// reaching the network.
    ///
    /// Readiness is checked here, before staging rather than after, because a
    /// proposal composed against a connector that cannot authenticate is one
    /// the user would read and approve and only then discover was never
    /// sendable.
    private func handleJiraIssueProposal(
        connector: HostControlConnector,
        arguments: [String: Any]
    ) -> MCPServerReply {
        let status = jiraStatus(connector: connector)
        guard status.ready else {
            diagnosticsRecorder?.record(
                toolName: "jira",
                summary: "jira propose_issue \(connector.alias) blocked: not configured",
                result: nil
            )
            return .result([
                "content": [["type": "text", "text": formattedJiraStatus(status)]],
                "isError": true
            ])
        }
        return JiraIssueProposalPolicy.stage(
            arguments: arguments,
            connector: connector,
            configuration: configuration,
            diagnostics: diagnosticsRecorder
        )
    }

    private func handleJiraReadRequest(
        operation: String,
        connector: HostControlConnector,
        arguments: [String: Any]
    ) -> MCPServerReply {
        let status = jiraStatus(connector: connector)
        guard status.ready else {
            diagnosticsRecorder?.record(toolName: "jira", summary: "jira \(operation) \(connector.alias) blocked: not configured", result: nil)
            return .result([
                "content": [[
                    "type": "text",
                    "text": formattedJiraStatus(status)
                ]],
                "isError": true
            ])
        }
        let request: JiraHTTPRequest
        do {
            request = try JiraRequestPolicy.readRequest(operation: operation, arguments: arguments)
        } catch {
            return .error(code: -32602, message: error.localizedDescription)
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"])
        let response = JiraHTTPClient(
            configuration: configuration,
            cancellationRegistry: cancellationRegistry
        ).request(
            connector: connector,
            request: request,
            timeoutSeconds: timeout,
            outputByteLimit: processLimits.outputByteLimit
        )
        let formattedResponse = response.formattedPayload(
            configuration: configuration,
            outputByteLimit: processLimits.outputByteLimit
        )
        diagnosticsRecorder?.record(toolName: "jira", summary: "jira \(operation) \(request.diagnosticPath)", result: response.diagnosticResult)
        return .result([
            "content": [[
                "type": "text",
                "text": formattedResponse.text
            ]],
            "isError": response.isError || formattedResponse.bodyTruncated
        ])
    }

    private func jiraConnector(alias: String?) -> HostControlConnector? {
        HostControlBrokeredServices.connector(forServiceType: "jira", alias: alias, in: configuration)
    }

    private func jiraStatus(connector: HostControlConnector) -> JiraConnectorStatus {
        let scheme = URL(string: connector.baseURL)?.scheme?.lowercased()
        let baseURLReady = scheme == "http" || scheme == "https"
        let emailKey = envKey(named: "JIRA_EMAIL", in: connector) ?? envKey(named: "EMAIL", in: connector)
        let tokenKey = envKey(named: "JIRA_API_TOKEN", in: connector) ?? envKey(named: "API_TOKEN", in: connector)
        let emailReady = emailKey.flatMap { configuration.environment[$0] }.map { !$0.isEmpty } ?? false
        let tokenReady = tokenKey.flatMap { configuration.environment[$0] }.map { !$0.isEmpty } ?? false
        return JiraConnectorStatus(
            alias: connector.alias,
            baseURL: connector.baseURL,
            baseURLReady: baseURLReady,
            emailEnvKey: emailKey,
            emailReady: emailReady,
            tokenEnvKey: tokenKey,
            tokenReady: tokenReady
        )
    }

    private func envKey(named logicalName: String, in connector: HostControlConnector) -> String? {
        if let key = connector.credentials[logicalName] ?? connector.env[logicalName] {
            return key
        }
        let normalized = logicalName.uppercased()
        return (Array(connector.credentials.values) + Array(connector.env.values)).first {
            $0.uppercased().hasSuffix(normalized) || $0.uppercased() == normalized
        }
    }

    private func formattedJiraStatus(_ status: JiraConnectorStatus) -> String {
        [
            "alias: \(status.alias)",
            "base_url: \(status.baseURLReady ? status.baseURL : "<missing or invalid>")",
            "email_env_key: \(status.emailEnvKey ?? "<missing>")",
            "email_present: \(status.emailReady)",
            "api_token_env_key: \(status.tokenEnvKey ?? "<missing>")",
            "api_token_present: \(status.tokenReady)",
            "ready: \(status.ready)"
        ].joined(separator: "\n")
    }

    private func redactedResult(_ result: HostControlCommandResult) -> HostControlCommandResult {
        let includeSecretFragments = result.stdoutTruncated || result.stderrTruncated || result.timedOut
        let stdout = configuration.redacted(result.stdout, includingSecretFragments: includeSecretFragments)
        let stderr = configuration.redacted(result.stderr, includingSecretFragments: includeSecretFragments)
        let cappedStdout = cappedRedactedOutput(stdout, label: "stdout", includeSecretFragments: includeSecretFragments)
        let cappedStderr = cappedRedactedOutput(stderr, label: "stderr", includeSecretFragments: includeSecretFragments)
        return HostControlCommandResult(
            command: result.command,
            arguments: result.arguments,
            exitCode: result.exitCode,
            stdout: cappedStdout.value,
            stderr: cappedStderr.value,
            timedOut: result.timedOut,
            stdoutTruncated: result.stdoutTruncated || cappedStdout.truncated,
            stderrTruncated: result.stderrTruncated || cappedStderr.truncated
        )
    }

    private func cappedRedactedOutput(
        _ value: String,
        label: String,
        includeSecretFragments: Bool
    ) -> HostControlCappedOutput {
        let capped = HostControlOutputCap.capped(value, label: "redacted \(label)", byteLimit: processLimits.outputByteLimit)
        guard includeSecretFragments || capped.truncated else { return capped }

        let redactedAfterCap = configuration.redacted(capped.value, includingSecretFragments: true)
        let recapped = HostControlOutputCap.capped(
            redactedAfterCap,
            label: "redacted \(label)",
            byteLimit: processLimits.outputByteLimit
        )
        let finalValue = configuration.redacted(recapped.value, includingSecretFragments: true)
        if finalValue == recapped.value {
            return HostControlCappedOutput(value: recapped.value, truncated: capped.truncated || recapped.truncated)
        }

        let finalCap = HostControlOutputCap.capped(
            finalValue,
            label: "redacted \(label)",
            byteLimit: processLimits.outputByteLimit
        )
        return HostControlCappedOutput(value: finalCap.value, truncated: capped.truncated || recapped.truncated || finalCap.truncated)
    }

    private func redactedDiagnosticArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var redactsNextValue = false
        for argument in arguments {
            if redactsNextValue {
                redacted.append("<redacted>")
                redactsNextValue = false
                continue
            }

            guard argument.hasPrefix("-") else {
                redacted.append(argument)
                continue
            }

            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let optionName = String(parts.first ?? "")
            guard isSensitiveDiagnosticOption(optionName) else {
                redacted.append(argument)
                continue
            }

            if parts.count > 1 {
                redacted.append("\(optionName)=<redacted>")
            } else {
                redacted.append(optionName)
                redactsNextValue = true
            }
        }
        return redacted
    }

    private func isSensitiveDiagnosticOption(_ optionName: String) -> Bool {
        optionName == "--account" ||
            optionName == "--configuration" ||
            optionName == "--flags-file" ||
            optionName == "--key-file" ||
            optionName == "--impersonate-service-account" ||
            optionName.contains("access-token") ||
            optionName.contains("identity-token") ||
            optionName.contains("credential") ||
            optionName.contains("password") ||
            optionName.contains("secret")
    }

    private func encodeCommandResult(result: HostControlCommandResult) -> MCPServerReply {
        .result([
            "content": [[
                "type": "text",
                "text": formatted(result)
            ]],
            "isError": result.exitCode != 0 || result.timedOut || result.stdoutTruncated || result.stderrTruncated
        ])
    }

    private func formatted(_ result: HostControlCommandResult) -> String {
        var lines = [
            "command: \(URL(fileURLWithPath: result.command).lastPathComponent)",
            "arguments: \(result.arguments.joined(separator: " "))",
            "exit_code: \(result.exitCode)"
        ]
        if result.timedOut {
            lines.append("timed_out: true")
        }
        if result.stdoutTruncated || result.stderrTruncated {
            lines.append("output_truncated: true")
        }
        if result.stdoutTruncated {
            lines.append("stdout_truncated: true")
        }
        if result.stderrTruncated {
            lines.append("stderr_truncated: true")
        }
        lines += [
            "stdout:",
            result.stdout.isEmpty ? "<empty>" : result.stdout,
            "stderr:",
            result.stderr.isEmpty ? "<empty>" : result.stderr
        ]
        return lines.joined(separator: "\n")
    }

    private func toolSchemas() -> [[String: Any]] {
        [
            processSchema(
                name: "github",
                description: "Run GitHub CLI control-plane commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Arguments for gh, for example [\"pr\", \"view\", \"123\", \"--comments\"]."
            ),
            processSchema(
                name: "gcloud",
                description: "Run read-only Google Cloud CLI control-plane commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Arguments for gcloud, for example [\"compute\", \"instances\", \"list\", \"--format=json\"]. Credential, mutating, debug, and BigQuery command groups are denied."
            ),
            processSchema(
                name: "bq",
                description: "Run BigQuery CLI help/version commands on the host through ASTRA without provider Bash.",
                argumentDescription: "Help-only bq arguments, for example [\"--help\"], [\"help\"], or [\"version\"]. Resource listing, display, query, export, load, delete, copy, table mutation, and job commands are denied."
            ),
            sshSchema(),
            jiraSchema(),
            REDCapHostControlPolicy.toolSchema(timeoutDescription: timeoutDescription(kind: "request"))
        ].filter { schema in
            guard let name = schema["name"] as? String else { return false }
            return toolIsAllowed(name)
        }
    }

    private func toolIsAllowed(_ toolName: String) -> Bool {
        configuration.allowedTools.contains(normalizedToolName(toolName))
    }

    private func normalizedToolName(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func processSchema(name: String, description: String, argumentDescription: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "arguments": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": argumentDescription
                    ],
                    "timeout_seconds": [
                        "type": "number",
                        "description": timeoutDescription(kind: "command")
                    ]
                ],
                "required": ["arguments"],
                "additionalProperties": false
            ]
        ]
    }

    private func sshSchema() -> [String: Any] {
        [
            "name": "ssh",
            "description": "Check a configured workspace SSH alias from the host using an ASTRA-owned non-interactive no-op. Caller-provided remote commands are not supported.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "alias": ["type": "string", "description": "Configured SSH Host alias or workspace SSH connection alias to check."],
                    "timeout_seconds": ["type": "number", "description": timeoutDescription(kind: "command")]
                ],
                "required": ["alias"],
                "additionalProperties": false
            ]
        ]
    }

    private func jiraSchema() -> [String: Any] {
        let description = """
            Use typed ASTRA-projected Jira connector operations on the host. Reads return data \
            directly. The one write, propose_issue, only stages a ticket for the user to approve — \
            this tool never posts to Jira and never exposes the credential, so do not fall back to \
            curl or a script.
            """
        return [
            "name": "jira",
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "operation": ["type": "string", "description": "status, get_issue, search_jql, get_comments, or propose_issue. Defaults to status."],
                    "alias": ["type": "string", "description": "Optional connector alias."],
                    "issue_key": ["type": "string", "description": "For get_issue and get_comments: Jira issue key, for example ASTRA-123."],
                    "jql": ["type": "string", "description": "For search_jql: Jira Query Language expression."],
                    "max_results": ["type": "number", "description": "For search_jql and get_comments: maximum result count from 1 to 100. Defaults to 20."],
                    "next_page_token": ["type": "string", "description": "For search_jql: opaque Jira nextPageToken returned by a previous page."],
                    "project_key": ["type": "string", "description": "For propose_issue: destination project key, for example STAR."],
                    "issue_type": ["type": "string", "description": "For propose_issue: issue type name as configured in the project, for example Bug."],
                    "summary": ["type": "string", "description": "For propose_issue: single-line ticket title, at most 255 characters."],
                    "description": ["type": "string", "description": "For propose_issue: ticket body as Jira wiki markup, at most 32768 characters. Jira renders it; do not send Atlassian Document Format JSON."],
                    "priority": ["type": "string", "description": "For propose_issue: optional priority name, for example Highest."],
                    "labels": ["type": "array", "items": ["type": "string"], "description": "For propose_issue: optional labels, at most 20. Each must be a single word without spaces."],
                    "assignee_account_id": ["type": "string", "description": "For propose_issue: optional Jira account id to assign."],
                    "parent_key": ["type": "string", "description": "For propose_issue: optional parent issue key, for example STAR-123."],
                    "timeout_seconds": ["type": "number", "description": timeoutDescription(kind: "request")]
                ],
                "additionalProperties": false
            ]
        ]
    }

    private func timeoutDescription(kind: String) -> String {
        let defaultTimeout = min(120, processLimits.maximumTimeoutSeconds)
        return "Optional \(kind) timeout. Defaults to \(formattedSeconds(defaultTimeout)) seconds and is capped at \(formattedSeconds(processLimits.maximumTimeoutSeconds)) seconds."
    }

    private func formattedSeconds(_ value: TimeInterval) -> String {
        if value.rounded(.towardZero) == value {
            return "\(Int(value))"
        }
        return "\(value)"
    }

    private func stringArray(_ value: Any?) -> [String]? {
        if let strings = value as? [String] {
            return strings
        }
        guard let values = value as? [Any] else { return nil }
        var strings: [String] = []
        for value in values {
            guard let string = value as? String else { return nil }
            strings.append(string)
        }
        return strings
    }

    private func validateArguments(_ values: [String]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !$0.contains("\n") && !$0.contains("\r")
        }
    }

    private func timeoutSeconds(from value: Any?) -> TimeInterval {
        let requested: TimeInterval? = switch value {
        case let number as NSNumber:
            number.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
        let finiteRequest = requested.flatMap { $0.isFinite ? $0 : nil }
        return processLimits.clampedTimeout(finiteRequest ?? 120)
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}

private enum HostControlSSHCommandPolicy {
    static let remoteCommandRejectionMessage =
        "ssh remote commands are not supported by ASTRA host control; use a reviewed workspace capability for remote command execution"

    private static let unsupportedCommandKeys: Set<String> = [
        "arguments",
        "cmd",
        "command",
        "remote_command"
    ]

    static func containsUnsupportedCommandInput(_ arguments: [String: Any]) -> Bool {
        !unsupportedCommandKeys.isDisjoint(with: arguments.keys)
    }

    static func connectionCheckArguments(for alias: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "RequestTTY=no",
            "-o", "StdinNull=yes",
            "-o", "ClearAllForwardings=yes",
            "--",
            alias,
            "true"
        ]
    }
}

private enum GCloudHostControlPolicy {
    private static let bigQueryGroup = "bq"
    private static let releaseTracks: Set<String> = ["alpha", "beta"]
    private static let globalOptionsWithValues: Set<String> = [
        "--account",
        "--access-token-file",
        "--api-endpoint-overrides",
        "--billing-project",
        "--configuration",
        "--filter",
        "--flags-file",
        "--flatten",
        "--format",
        "--impersonate-service-account",
        "--limit",
        "--page-size",
        "--project",
        "--sort-by",
        "--trace-token",
        "--verbosity"
    ]

    static func rejectionMessage(arguments: [String]) -> String? {
        let commandPath = commandPathTokens(arguments)
        guard isBigQueryCommandFamily(commandPath) else {
            return nil
        }
        return [
            "gcloud command is not allowed by ASTRA host-control policy: BigQuery command group.",
            "Use the bq host-control tool for help/version metadata only, or an explicitly approved BigQuery capability for resource access."
        ].joined(separator: " ")
    }

    private static func isBigQueryCommandFamily(_ commandPath: [String]) -> Bool {
        guard let first = commandPath.first?.lowercased() else {
            return false
        }
        if first == bigQueryGroup {
            return true
        }
        guard releaseTracks.contains(first),
              let second = commandPath.dropFirst().first?.lowercased() else {
            return false
        }
        return second == bigQueryGroup
    }

    private static func commandPathTokens(_ arguments: [String]) -> [String] {
        var tokens: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                let optionName = optionName(for: token)
                index += 1
                if globalOptionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                    index += 1
                }
                continue
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }

    private static func optionName(for token: String) -> String {
        token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
    }
}

private enum BigQueryHostControlPolicy {
    private static let allowedCommands: Set<String> = ["help", "version"]
    private static let helpOptions: Set<String> = ["--help", "-h"]
    private static let versionOptions: Set<String> = ["--version"]
    private static let globalOptionsWithValues: Set<String> = [
        "--format",
        "--location",
        "--max_results",
        "--page_token",
        "--project_id"
    ]

    static func rejectionMessage(arguments: [String]) -> String? {
        if isBareHelpOrVersion(arguments) {
            return nil
        }

        let actionTokens: [String]
        switch actionTokensAfterLeadingOptions(arguments) {
        case .allowed(let tokens):
            actionTokens = tokens
        case .blocked(let token):
            return blockedMessage(command: token)
        }

        guard let command = actionTokens.first?.lowercased() else {
            return blockedMessage(command: "<missing>")
        }
        guard allowedCommands.contains(command) else {
            return blockedMessage(command: command)
        }
        if let blockedOption = firstPostCommandOption(in: actionTokens.dropFirst()) {
            return blockedMessage(command: blockedOption)
        }
        return nil
    }

    private enum LeadingOptionParse {
        case allowed([String])
        case blocked(String)
    }

    private static func actionTokensAfterLeadingOptions(_ arguments: [String]) -> LeadingOptionParse {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else { break }

            let optionName = optionName(for: token)
            if helpOptions.contains(optionName) || versionOptions.contains(optionName) {
                index += 1
                continue
            }
            guard globalOptionsWithValues.contains(optionName) else {
                return .blocked(optionName)
            }

            index += 1
            if !token.contains("=") {
                guard index < arguments.count else {
                    return .blocked(optionName)
                }
                index += 1
            }
        }
        return .allowed(Array(arguments.dropFirst(index)))
    }

    private static func isBareHelpOrVersion(_ arguments: [String]) -> Bool {
        !arguments.isEmpty && arguments.allSatisfy { token in
            let optionName = optionName(for: token)
            return helpOptions.contains(optionName) || versionOptions.contains(optionName)
        }
    }

    private static func firstPostCommandOption(in arguments: ArraySlice<String>) -> String? {
        arguments.first { $0.hasPrefix("-") }.map(optionName(for:))
    }

    private static func optionName(for token: String) -> String {
        token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
    }

    private static func blockedMessage(command: String) -> String {
        [
            "bq command is not allowed by ASTRA host-control policy: '\(command)'.",
            "Allowed bq operations are help/version only: help and version commands, or bare --help, -h, and --version flags.",
            "Use an explicitly approved BigQuery capability for query, export, load, delete, copy, table mutation, or job operations."
        ].joined(separator: " ")
    }
}

private struct JiraConnectorStatus {
    var alias: String
    var baseURL: String
    var baseURLReady: Bool
    var emailEnvKey: String?
    var emailReady: Bool
    var tokenEnvKey: String?
    var tokenReady: Bool

    var ready: Bool {
        baseURLReady && emailReady && tokenReady
    }
}

struct JiraHTTPResponse {
    var statusCode: Int
    var body: String
    var errorMessage: String?
    var bodyTruncated: Bool = false

    var isError: Bool {
        if errorMessage != nil || bodyTruncated { return true }
        return statusCode < 200 || statusCode >= 300
    }

    var diagnosticResult: HostControlCommandResult {
        HostControlCommandResult(
            command: "jira",
            arguments: ["request"],
            exitCode: isError ? 1 : 0,
            stdout: body,
            stderr: errorMessage ?? "",
            stdoutTruncated: bodyTruncated
        )
    }

    func formatted(configuration: HostControlToolConfiguration, outputByteLimit: Int) -> String {
        formattedPayload(configuration: configuration, outputByteLimit: outputByteLimit).text
    }

    func formattedPayload(configuration: HostControlToolConfiguration, outputByteLimit: Int) -> FormattedJiraHTTPResponse {
        let redactedBody = configuration.redacted(body, includingSecretFragments: bodyTruncated)
        let formattedBody = Self.cappedRedactedOutput(
            redactedBody,
            label: "Jira response body",
            byteLimit: outputByteLimit,
            configuration: configuration,
            includeSecretFragments: bodyTruncated
        )
        var lines = [
            "status_code: \(statusCode)",
            "body:",
            formattedBody.value.isEmpty ? "<empty>" : formattedBody.value,
            "error:",
            errorMessage.map { configuration.redacted($0, includingSecretFragments: bodyTruncated) } ?? "<empty>"
        ]
        if bodyTruncated || formattedBody.truncated {
            lines.insert("body_truncated: true", at: 1)
        }
        return FormattedJiraHTTPResponse(
            text: lines.joined(separator: "\n"),
            bodyTruncated: bodyTruncated || formattedBody.truncated
        )
    }

    private static func cappedRedactedOutput(
        _ value: String,
        label: String,
        byteLimit: Int,
        configuration: HostControlToolConfiguration,
        includeSecretFragments: Bool
    ) -> HostControlCappedOutput {
        HostControlRedactedBody.capped(
            value,
            label: label,
            byteLimit: byteLimit,
            configuration: configuration,
            includeSecretFragments: includeSecretFragments
        )
    }
}

struct FormattedJiraHTTPResponse {
    var text: String
    var bodyTruncated: Bool
}

private final class BoundedJiraHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let buffer: BoundedProcessOutput
    private let lock = NSLock()
    private var statusCode = 0
    private var errorMessage: String?
    private var bodyTruncated = false

    init(semaphore: DispatchSemaphore, outputByteLimit: Int) {
        self.semaphore = semaphore
        self.buffer = BoundedProcessOutput(label: "Jira response body", byteLimit: outputByteLimit)
    }

    var response: JiraHTTPResponse {
        let body = buffer.cappedStringValue
        lock.lock()
        let snapshot = JiraHTTPResponse(
            statusCode: statusCode,
            body: body.value,
            errorMessage: errorMessage,
            bodyTruncated: bodyTruncated || body.truncated
        )
        lock.unlock()
        return snapshot
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if buffer.append(data) {
            lock.lock()
            bodyTruncated = true
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            if !bodyTruncated {
                errorMessage = error.localizedDescription
            }
            lock.unlock()
        }
        semaphore.signal()
    }
}

private final class JiraHTTPClient {
    private let configuration: HostControlToolConfiguration
    private let cancellationRegistry: HostControlOperationCancellationRegistry

    init(
        configuration: HostControlToolConfiguration,
        cancellationRegistry: HostControlOperationCancellationRegistry
    ) {
        self.configuration = configuration
        self.cancellationRegistry = cancellationRegistry
    }

    func request(
        connector: HostControlConnector,
        request jiraRequest: JiraHTTPRequest,
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int
    ) -> JiraHTTPResponse {
        guard let url = url(baseURL: connector.baseURL, request: jiraRequest) else {
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Invalid Jira base URL or path")
        }
        guard let email = credential(named: "JIRA_EMAIL", connector: connector) ?? credential(named: "EMAIL", connector: connector),
              let token = credential(named: "JIRA_API_TOKEN", connector: connector) ?? credential(named: "API_TOKEN", connector: connector) else {
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Jira connector credentials are not projected")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = jiraRequest.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let tokenData = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(tokenData)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        let delegate = BoundedJiraHTTPDelegate(semaphore: semaphore, outputByteLimit: outputByteLimit)
        let sessionConfiguration = HostControlURLSessionConfiguration.brokeredHTTPConfiguration()
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        let cancelled = LockedFlag()
        let cancellationRegistration = cancellationRegistry.register {
            _ = cancelled.setIfUnset()
            task.cancel()
            session.invalidateAndCancel()
            semaphore.signal()
        }
        defer {
            cancellationRegistry.unregister(cancellationRegistration)
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Timed out after \(Int(timeoutSeconds))s")
        }
        if cancelled.isSet {
            return JiraHTTPResponse(statusCode: 0, body: "", errorMessage: "Cancelled by ASTRA.")
        }
        session.finishTasksAndInvalidate()
        return delegate.response
    }

    private func url(baseURL: String, request: JiraHTTPRequest) -> URL? {
        guard var url = URL(string: baseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        for segment in request.path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
        return components.url
    }

    private func credential(named logicalName: String, connector: HostControlConnector) -> String? {
        let upper = logicalName.uppercased()
        let envKey = connector.credentials[logicalName]
            ?? connector.env[logicalName]
            ?? (Array(connector.credentials.values) + Array(connector.env.values)).first {
                $0.uppercased().hasSuffix(upper) || $0.uppercased() == upper
            }
        guard let envKey,
              let value = configuration.environment[envKey],
              !value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

public enum AstraHostControlToolMain {
    public static func run() {
        let configuration = HostControlToolConfiguration.fromEnvironment()
        let recorder = HostControlToolDiagnosticsRecorder(configuration: configuration)
        let server = HostControlMCPServer(configuration: configuration, diagnosticsRecorder: recorder)
        while let line = readLine() {
            if let response = server.handleLine(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}

private final class ProcessOutputReadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var stopped = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    /// `onReadable` runs entirely inside this handle's lock, atomically with
    /// the stop decision it returns. Without that, `claimForDrain()` could
    /// hand the fd to a manual drain loop (which reconfigures and then
    /// closes it) while a readability event dispatched moments earlier is
    /// still running this closure, unsynchronized — the stale invocation
    /// would then touch an already-closed, possibly already-recycled
    /// descriptor. Returning `true` stops future callbacks, same as the old
    /// explicit `.stop()` call this replaces.
    func setReadabilityHandler(_ onReadable: @escaping @Sendable (FileHandle) -> Bool) {
        handle.readabilityHandler = { handle in
            self.lock.lock()
            guard !self.stopped, onReadable(handle) else {
                self.lock.unlock()
                return
            }
            self.stopped = true
            self.handle.readabilityHandler = nil
            self.lock.unlock()
            // Matches the old inline `.stop()` calls this closure replaces:
            // close promptly so an output-limited child that ignores
            // SIGTERM gets EPIPE/SIGPIPE on its next write instead of
            // filling the pipe buffer and blocking until the kill grace
            // period expires.
            try? handle.close()
        }
    }

    func stop() {
        guard let handle = claimLocked() else { return }
        try? handle.close()
    }

    func claimForDrain() -> FileHandle? {
        claimLocked()
    }

    private func claimLocked() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        stopped = true
        handle.readabilityHandler = nil
        return handle
    }
}

final class BoundedProcessOutput: @unchecked Sendable {
    private static let truncationBoundarySafetyBytes = 512

    private let lock = NSLock()
    private let label: String
    private let byteLimit: Int
    private var data = Data()
    private var truncated = false

    init(label: String, byteLimit: Int) {
        self.label = label
        self.byteLimit = byteLimit
    }

    func append(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }

        guard !truncated else { return false }
        let remaining = max(0, byteLimit - data.count)
        if remaining >= chunk.count {
            data.append(chunk)
            return false
        }
        appendTruncationMarkerLocked(afterAppendingPrefixFrom: chunk)
        return true
    }

    func markTruncated() {
        lock.lock()
        defer { lock.unlock() }

        guard !truncated else { return }
        appendTruncationMarkerLocked()
    }

    private func appendTruncationMarkerLocked(afterAppendingPrefixFrom chunk: Data? = nil) {
        let marker = "\n[ASTRA truncated \(label) after \(byteLimit) bytes]\n"
        let markerData = Data(marker.utf8)
        let markerBytesToKeep = min(byteLimit, markerData.count)
        let outputBytesToKeep = max(0, byteLimit - markerBytesToKeep - Self.truncationBoundarySafetyBytes)
        if let chunk, data.count < outputBytesToKeep {
            data.append(chunk.prefix(outputBytesToKeep - data.count))
        }
        if data.count > outputBytesToKeep {
            data.removeLast(data.count - outputBytesToKeep)
        }
        data.append(markerData.prefix(byteLimit - data.count))
        truncated = true
    }

    var isTruncated: Bool {
        lock.lock()
        let snapshot = truncated
        lock.unlock()
        return snapshot
    }

    var cappedStringValue: HostControlCappedOutput {
        lock.lock()
        let snapshot = data
        lock.unlock()
        let decoded = String(data: snapshot, encoding: .utf8) ?? String(decoding: snapshot, as: UTF8.self)
        return HostControlOutputCap.capped(decoded, label: label, byteLimit: byteLimit)
    }
}
