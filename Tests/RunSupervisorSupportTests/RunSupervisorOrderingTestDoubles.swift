import Darwin
import Foundation
@testable import RunSupervisorSupport

struct SynchronousCancellationLauncher: RunSupervisorProviderLaunching {
    let process: SynchronousCancellationProcess

    func makeProcess(
        _ request: RunSupervisorProviderLaunchRequest
    ) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

struct ImmediateOutputExitLauncher: RunSupervisorProviderLaunching {
    let process: ImmediateOutputExitProcess

    func makeProcess(
        _ request: RunSupervisorProviderLaunchRequest
    ) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

struct DelayedDrainExitLauncher: RunSupervisorProviderLaunching {
    let process: DelayedDrainExitProcess

    func makeProcess(
        _ request: RunSupervisorProviderLaunchRequest
    ) throws -> any RunSupervisorOwnedProcess {
        process
    }
}

final class SynchronousCancellationProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var terminated = false

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_996 }

    func setTerminationHandler(
        _ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void
    ) {
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
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        handler?(.init(exitCode: 143, signal: SIGTERM))
        return true
    }
}

final class ImmediateOutputExitProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_995 }

    func setTerminationHandler(
        _ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void
    ) {
        self.handler = handler
    }

    func run() throws {
        try stdoutPipe.fileHandleForWriting.write(contentsOf: Data("immediate-output".utf8))
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        handler?(.init(exitCode: 0, signal: nil))
    }

    func writeStandardInputLine(_ line: String) throws {}
    func closeStandardInput() throws -> Bool { true }
    func requestGracefulCancellation() -> Bool { false }
    func terminateImmediately() -> Bool { false }
}

final class DelayedDrainExitProcess: RunSupervisorOwnedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let outputReaderRequested = DispatchSemaphore(value: 0)
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var handler: (@Sendable (RunSupervisorProcessTermination) -> Void)?
    private var didPublishReader = false

    init() {
        stderrPipe.fileHandleForWriting.closeFile()
    }

    var stdoutFileHandle: FileHandle {
        lock.lock()
        let shouldSignal = !didPublishReader
        didPublishReader = true
        lock.unlock()
        if shouldSignal { outputReaderRequested.signal() }
        return stdoutPipe.fileHandleForReading
    }

    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }
    var processIdentifierDiagnostic: Int32? { 99_994 }

    func setTerminationHandler(
        _ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void
    ) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func run() throws {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(.init(exitCode: 0, signal: nil))
    }

    func waitUntilOutputReaderRequested() -> Bool {
        outputReaderRequested.wait(timeout: .now() + 5) == .success
    }

    func emitAndClose(_ data: Data) throws {
        try stdoutPipe.fileHandleForWriting.write(contentsOf: data)
        stdoutPipe.fileHandleForWriting.closeFile()
    }

    func writeStandardInputLine(_ line: String) throws {}
    func closeStandardInput() throws -> Bool { true }
    func requestGracefulCancellation() -> Bool { false }

    func terminateImmediately() -> Bool {
        stdoutPipe.fileHandleForWriting.closeFile()
        return false
    }
}
