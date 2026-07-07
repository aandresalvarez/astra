import Foundation

public struct HardenedProcessRequest: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var standardInput: Data?
    public var timeout: TimeInterval
    public var environment: [String: String]?
    public var currentDirectory: String?
    public var maximumOutputBytes: Int?
    public var terminateProcessGroup: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        standardInput: Data? = nil,
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        maximumOutputBytes: Int? = nil,
        terminateProcessGroup: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.maximumOutputBytes = maximumOutputBytes
        self.terminateProcessGroup = terminateProcessGroup
    }
}

public struct HardenedProcessExecutor: Sendable {
    private let runner: ProcessBinaryRunner

    public init(runner: ProcessBinaryRunner = ProcessBinaryRunner()) {
        self.runner = runner
    }

    public func run(_ request: HardenedProcessRequest) async -> RunResult {
        let launch = launchPlan(for: request)
        return await runner.run(
            path: launch.path,
            args: launch.arguments,
            timeout: effectiveTimeout(request.timeout),
            environment: request.environment,
            currentDirectory: request.currentDirectory,
            stdin: request.standardInput,
            maximumOutputBytes: request.maximumOutputBytes,
            terminateProcessGroup: request.terminateProcessGroup
        )
    }

    public func runSynchronously(_ request: HardenedProcessRequest) -> RunResult {
        let box = HardenedProcessResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await run(request)
            box.store(result)
            semaphore.signal()
        }
        semaphore.wait()
        return box.result ?? .cancelled(stdout: "", stderr: "")
    }

    private func launchPlan(for request: HardenedProcessRequest) -> (path: String, arguments: [String]) {
        if request.executable.hasPrefix("/") {
            return (request.executable, request.arguments)
        }
        return ("/usr/bin/env", [request.executable] + request.arguments)
    }

    private func effectiveTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { return 1 }
        return timeout
    }
}

private final class HardenedProcessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: RunResult?

    public var result: RunResult? {
        lock.lock()
        let value = storedResult
        lock.unlock()
        return value
    }

    public func store(_ result: RunResult) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }
}
