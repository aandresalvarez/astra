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
        let expectsStructuredToolEvents: Bool
        let expectsResultCallback: Bool

        var description: String {
            runtimeID.displayName
        }
    }

    enum RuntimeCaseAvailability: Equatable {
        case runnable
        case unavailable(String)

        var isRunnable: Bool {
            if case .runnable = self { return true }
            return false
        }

        var diagnostic: String? {
            if case .unavailable(let diagnostic) = self { return diagnostic }
            return nil
        }
    }

    typealias RuntimeCaseAvailabilityProvider = (RuntimeCase) -> RuntimeCaseAvailability

    static var runtimeCases: [RuntimeCase] {
        runtimeCases(environment: ProcessInfo.processInfo.environment)
    }

    static func runtimeCases(environment: [String: String]) -> [RuntimeCase] {
        runtimeCases(environment: environment, availability: defaultRuntimeCaseAvailability)
    }

    static func runtimeCases(
        environment: [String: String],
        availability: RuntimeCaseAvailabilityProvider
    ) -> [RuntimeCase] {
        let config = LiveProviderTestConfiguration(environment: environment)
        let cases = [
            RuntimeCase(
                runtimeID: .claudeCode,
                model: config.claudeModel,
                directoryNameComponent: "claude",
                expectsSessionID: true,
                expectsUsageStats: true,
                expectsCostUSD: true,
                expectsTeamEvents: true,
                expectsStructuredToolEvents: true,
                expectsResultCallback: true
            ),
            RuntimeCase(
                runtimeID: .copilotCLI,
                model: config.copilotModel,
                directoryNameComponent: "copilot",
                expectsSessionID: false,
                expectsUsageStats: false,
                expectsCostUSD: false,
                expectsTeamEvents: false,
                expectsStructuredToolEvents: true,
                expectsResultCallback: true
            ),
            RuntimeCase(
                runtimeID: .antigravityCLI,
                model: config.antigravityModel,
                directoryNameComponent: "antigravity",
                expectsSessionID: false,
                expectsUsageStats: false,
                expectsCostUSD: false,
                expectsTeamEvents: false,
                expectsStructuredToolEvents: false,
                expectsResultCallback: false
            ),
            RuntimeCase(
                runtimeID: .cursorCLI,
                model: config.cursorModel,
                directoryNameComponent: "cursor",
                expectsSessionID: true,
                expectsUsageStats: true,
                expectsCostUSD: false,
                expectsTeamEvents: false,
                expectsStructuredToolEvents: false,
                expectsResultCallback: true
            ),
            RuntimeCase(
                runtimeID: .openCodeCLI,
                model: config.openCodeModel,
                directoryNameComponent: "opencode",
                expectsSessionID: false,
                expectsUsageStats: false,
                expectsCostUSD: false,
                expectsTeamEvents: false,
                expectsStructuredToolEvents: false,
                expectsResultCallback: true
            )
        ]
        let requested = (environment["RUN_E2E_RUNTIME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !requested.isEmpty else {
            return liveRunnableRuntimeCases(from: cases, environment: environment, availability: availability)
        }
        let filtered = cases.filter { runtimeCase in
            runtimeCase.runtimeID.rawValue.lowercased() == requested
                || runtimeCase.directoryNameComponent.lowercased() == requested
        }
        if filtered.isEmpty {
            fputs("Unknown RUN_E2E_RUNTIME '\(requested)'; running all runtime cases instead.\n", stderr)
            return liveRunnableRuntimeCases(from: cases, environment: environment, availability: availability)
        }
        return filtered
    }

    private static func liveRunnableRuntimeCases(
        from cases: [RuntimeCase],
        environment: [String: String],
        availability: RuntimeCaseAvailabilityProvider
    ) -> [RuntimeCase] {
        guard environment["RUN_E2E"] != nil,
              environment["RUN_E2E_INCLUDE_UNREADY"] == nil else {
            return cases
        }
        let evaluated = cases.map { runtimeCase in
            (runtimeCase: runtimeCase, availability: availability(runtimeCase))
        }
        let runnable = evaluated
            .filter(\.availability.isRunnable)
            .map(\.runtimeCase)
        evaluated
            .filter { !$0.availability.isRunnable }
            .forEach { item in
                let reason = item.availability.diagnostic ?? "runtime is not ready"
                fputs("Skipping live E2E runtime \(item.runtimeCase.description): \(reason)\n", stderr)
            }
        return runnable.isEmpty ? cases : runnable
    }

    private static func defaultRuntimeCaseAvailability(_ runtimeCase: RuntimeCase) -> RuntimeCaseAvailability {
        guard let path = executablePath(for: runtimeCase.runtimeID),
              FileManager.default.isExecutableFile(atPath: path) else {
            return .unavailable("\(runtimeCase.description) executable was not found")
        }
        if let failure = LiveProviderReadiness.check(runtimeID: runtimeCase.runtimeID, executablePath: path) {
            return .unavailable(failure.message)
        }
        return .runnable
    }

    private static func executablePath(for runtimeID: AgentRuntimeID) -> String? {
        switch runtimeID {
        case .claudeCode:
            return RuntimePathResolver.detectClaudePath()
        case .copilotCLI:
            return RuntimePathResolver.detectCopilotPath()
        case .antigravityCLI:
            return RuntimePathResolver.detectAntigravityPath()
        case .cursorCLI:
            return RuntimePathResolver.detectCursorPath()
        case .openCodeCLI:
            return RuntimePathResolver.detectOpenCodePath()
        default:
            return nil
        }
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
            try requireLiveProviderReady(runtimeID: runtimeID, executablePath: path)
            worker.claudePath = path
        case .copilotCLI:
            let path = RuntimePathResolver.detectCopilotPath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("copilot")
            }
            try requireLiveProviderReady(runtimeID: runtimeID, executablePath: path)
            worker.copilotPath = path
            if let temporaryRootPath {
                worker.copilotHome = copilotHomePath(forTemporaryRootPath: temporaryRootPath)
            }
        case .antigravityCLI:
            let path = RuntimePathResolver.detectAntigravityPath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("agy")
            }
            try requireLiveProviderReady(runtimeID: runtimeID, executablePath: path)
            worker.setExecutablePath(path, for: .antigravityCLI)
        case .cursorCLI:
            let path = RuntimePathResolver.detectCursorPath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("cursor-agent")
            }
            try requireLiveProviderReady(runtimeID: runtimeID, executablePath: path)
            worker.setExecutablePath(path, for: .cursorCLI)
        case .openCodeCLI:
            let path = RuntimePathResolver.detectOpenCodePath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("opencode")
            }
            try requireLiveProviderReady(runtimeID: runtimeID, executablePath: path)
            worker.setExecutablePath(path, for: .openCodeCLI)
        default:
            throw E2ETestSupportError.missingExecutable(runtimeID.rawValue)
        }
    }

    private static func requireLiveProviderReady(runtimeID: AgentRuntimeID, executablePath: String) throws {
        guard ProcessInfo.processInfo.environment["RUN_E2E"] != nil else { return }
        try LiveProviderReadiness.requireReady(runtimeID: runtimeID, executablePath: executablePath)
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
    @Test("Runtime cases include Antigravity, Cursor, OpenCode, and support runtime filtering")
    func runtimeCasesIncludeAntigravityCursorOpenCodeAndSupportFiltering() {
        let allCases = E2ETestSupport.runtimeCases(environment: [:])
        #expect(allCases.map(\.runtimeID) == [.claudeCode, .copilotCLI, .antigravityCLI, .cursorCLI, .openCodeCLI])

        let filteredByID = E2ETestSupport.runtimeCases(environment: [
            "RUN_E2E_RUNTIME": "antigravity_cli",
            "REAL_ANTIGRAVITY_MODEL": "Gemini Test Model"
        ])
        #expect(filteredByID.map(\.runtimeID) == [.antigravityCLI])
        #expect(filteredByID.first?.model == "Gemini Test Model")

        let filteredByName = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "antigravity"])
        #expect(filteredByName.map(\.runtimeID) == [.antigravityCLI])

        let filteredByCursorName = E2ETestSupport.runtimeCases(environment: [
            "RUN_E2E_RUNTIME": "cursor",
            "REAL_CURSOR_MODEL": "Cursor Test Model"
        ])
        #expect(filteredByCursorName.map(\.runtimeID) == [.cursorCLI])
        #expect(filteredByCursorName.first?.model == "Cursor Test Model")

        let filteredByOpenCodeName = E2ETestSupport.runtimeCases(environment: [
            "RUN_E2E_RUNTIME": "opencode",
            "REAL_OPENCODE_MODEL": "OpenCode Test Model"
        ])
        #expect(filteredByOpenCodeName.map(\.runtimeID) == [.openCodeCLI])
        #expect(filteredByOpenCodeName.first?.model == "OpenCode Test Model")

        let unknownFilter = E2ETestSupport.runtimeCases(environment: ["RUN_E2E_RUNTIME": "not-a-runtime"])
        #expect(unknownFilter.map(\.runtimeID) == [.claudeCode, .copilotCLI, .antigravityCLI, .cursorCLI, .openCodeCLI])
    }

    @Test("All-runtime live selection omits unavailable providers")
    func allRuntimeLiveSelectionOmitsUnavailableProviders() {
        let cases = E2ETestSupport.runtimeCases(
            environment: ["RUN_E2E": "1", "RUN_REAL_PROVIDERS": "1"],
            availability: { runtimeCase in
                runtimeCase.runtimeID == .openCodeCLI
                    ? .unavailable("OpenCode has 0 credentials")
                    : .runnable
            }
        )

        #expect(cases.map(\.runtimeID) == [.claudeCode, .copilotCLI, .antigravityCLI, .cursorCLI])
    }

    @Test("Explicit live runtime selection keeps unavailable provider for fail-fast diagnostics")
    func explicitLiveRuntimeSelectionKeepsUnavailableProvider() {
        let cases = E2ETestSupport.runtimeCases(
            environment: ["RUN_E2E": "1", "RUN_REAL_PROVIDERS": "1", "RUN_E2E_RUNTIME": "opencode"],
            availability: { _ in .unavailable("OpenCode has 0 credentials") }
        )

        #expect(cases.map(\.runtimeID) == [.openCodeCLI])
    }

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

    @Test("Shared runtime state gate removes cancelled waiters")
    func sharedRuntimeStateGateRemovesCancelledWaiters() async throws {
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        try await AgentRuntimeSharedStateGate.shared.acquire(key)
        let waiterRan = AsyncTestFlag()

        let waiter = Task {
            try await AgentRuntimeSharedStateGate.shared.acquire(key)
            await waiterRan.set()
            await AgentRuntimeSharedStateGate.shared.release(key)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        let waiterFinished = await taskFinishesWithinTimeout(waiter, nanoseconds: 500_000_000)
        #expect(waiterFinished)
        #expect(await waiterRan.value == false)

        await AgentRuntimeSharedStateGate.shared.release(key)
        try await AgentRuntimeSharedStateGate.shared.acquire(key)
        await AgentRuntimeSharedStateGate.shared.release(key)
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
