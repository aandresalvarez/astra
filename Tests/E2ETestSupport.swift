import Foundation
import Testing
@testable import ASTRA
import ASTRACore

enum E2ETestSupport {
    struct RuntimeCase: Sendable, CustomStringConvertible {
        let runtimeID: AgentRuntimeID
        let model: String
        let directoryNameComponent: String
        let expectsSessionID: Bool
        let expectsUsageStats: Bool
        let expectsCostUSD: Bool
        let expectsTeamEvents: Bool

        var description: String {
            runtimeID.displayName
        }
    }

    static var runtimeCases: [RuntimeCase] {
        [
            RuntimeCase(
                runtimeID: .claudeCode,
                model: ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode),
                directoryNameComponent: "claude",
                expectsSessionID: true,
                expectsUsageStats: true,
                expectsCostUSD: true,
                expectsTeamEvents: true
            ),
            RuntimeCase(
                runtimeID: .copilotCLI,
                model: ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI),
                directoryNameComponent: "copilot",
                expectsSessionID: false,
                expectsUsageStats: false,
                expectsCostUSD: false,
                expectsTeamEvents: false
            )
        ]
    }

    @MainActor
    static func configureUnattended(
        _ worker: AgentRuntimeWorker,
        for runtimeCase: RuntimeCase? = nil,
        temporaryRootPath: String? = nil
    ) throws {
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue

        if let runtimeCase {
            worker.defaultRuntimeID = runtimeCase.runtimeID
            try configureExecutable(for: runtimeCase.runtimeID, worker: worker, temporaryRootPath: temporaryRootPath)
        }

        if let timeout = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") {
            worker.timeoutSeconds = timeout
        }
    }

    @MainActor
    private static func configureExecutable(
        for runtimeID: AgentRuntimeID,
        worker: AgentRuntimeWorker,
        temporaryRootPath: String?
    ) throws {
        switch runtimeID {
        case .claudeCode:
            let path = RuntimePathResolver.detectClaudePath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("claude")
            }
            worker.claudePath = path
        case .copilotCLI:
            let path = RuntimePathResolver.detectCopilotPath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("copilot")
            }
            worker.copilotPath = path
            if let temporaryRootPath {
                worker.copilotHome = copilotHomePath(forTemporaryRootPath: temporaryRootPath)
            }
        default:
            throw E2ETestSupportError.missingExecutable(runtimeID.rawValue)
        }
    }

    static func copilotHomePath(forTemporaryRootPath path: String) -> String {
        "\(path)-copilot-home"
    }

    static func hasProviderProgressEvent(_ eventTypes: Set<String>) -> Bool {
        let progressEventTypes: Set<String> = [
            "agent.thinking",
            "agent.response",
            "tool.use",
            "tool.result",
            "astra.complete"
        ]
        return !eventTypes.isDisjoint(with: progressEventTypes)
    }

    static func withLiveProviderSlot<T>(_ operation: () async throws -> T) async throws -> T {
        try await E2ELiveProviderGate.shared.acquire()
        do {
            let result = try await operation()
            await E2ELiveProviderGate.shared.release()
            return result
        } catch {
            await E2ELiveProviderGate.shared.release()
            throw error
        }
    }
}

private actor E2ELiveProviderGate {
    static let shared = E2ELiveProviderGate()

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        if !isOccupied {
            isOccupied = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await enqueueWaiter(id: waiterID)
        } onCancel: {
            Task { await E2ELiveProviderGate.shared.cancelWaiter(id: waiterID) }
        }

        guard acquired else {
            throw CancellationError()
        }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func enqueueWaiter(id: UUID) async -> Bool {
        if Task.isCancelled {
            return false
        }

        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

@Suite("E2E live provider gate")
struct E2ELiveProviderGateTests {
    @Test("Queued live provider waiters finish when cancelled")
    func queuedLiveProviderWaitersFinishWhenCancelled() async throws {
        let holderReady = AsyncTestLatch()
        let releaseHolder = AsyncTestLatch()
        let waiterRan = AsyncTestFlag()

        let holder = Task {
            try await E2ETestSupport.withLiveProviderSlot {
                await holderReady.open()
                await releaseHolder.wait()
            }
        }
        await holderReady.wait()

        let waiter = Task {
            try await E2ETestSupport.withLiveProviderSlot {
                await waiterRan.set()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        let waiterFinished = await taskFinishesWithinTimeout(waiter, nanoseconds: 500_000_000)
        #expect(waiterFinished)
        #expect(await waiterRan.value == false)

        await releaseHolder.open()
        try await holder.value
        _ = try await E2ETestSupport.withLiveProviderSlot { true }
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AsyncTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private func taskFinishesWithinTimeout<T>(_ task: Task<T, Error>, nanoseconds: UInt64) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            do {
                _ = try await task.value
            } catch {
                // Cancellation is the expected path; any completion means the waiter was not leaked.
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

enum E2ETestSupportError: Error, CustomStringConvertible {
    case missingExecutable(String)

    var description: String {
        switch self {
        case .missingExecutable(let name):
            "Missing required E2E executable: \(name)"
        }
    }
}
