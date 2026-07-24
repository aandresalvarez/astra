import ASTRACore
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
    func setTerminationHandler(
        _ handler: @escaping @Sendable (RunSupervisorProcessTermination) -> Void
    )
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
    func makeProcess(
        _ request: RunSupervisorProviderLaunchRequest
    ) throws -> any RunSupervisorOwnedProcess
}

public struct DarwinRunSupervisorProviderLauncher: RunSupervisorProviderLaunching {
    public init() {}

    public func makeProcess(
        _ request: RunSupervisorProviderLaunchRequest
    ) throws -> any RunSupervisorOwnedProcess {
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
    public func writeStandardInputLine(_ line: String) throws {
        try process.writeStdinLineChecked(line)
    }
    public func closeStandardInput() throws -> Bool { try process.closeStdinChannelChecked() }
    public func requestGracefulCancellation() -> Bool { false }
    public func terminateImmediately() -> Bool { process.terminateImmediately() }
}
