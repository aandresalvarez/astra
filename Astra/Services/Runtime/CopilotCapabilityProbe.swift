import Foundation
import ASTRACore

/// One in-flight help query per binary identity. Each consumer owns its deadline
/// and cancellation; stopping one consumer never cancels another consumer's query.
actor CopilotCapabilityProbe {
    static let shared = CopilotCapabilityProbe()

    typealias Query = @Sendable (String) async -> RunResult
    private let query: Query

    init() {
        query = { path in
            await ProcessBinaryRunner().run(path: path, args: ["help"], timeout: 60,
                environment: RuntimeProcessEnvironment.enriched(), currentDirectory: nil,
                maximumOutputBytes: 1_048_576, terminateProcessGroup: true)
        }
    }

    init(query: @escaping Query) { self.query = query }

    enum Failure: Error, LocalizedError {
        case timedOut, unanswered
        var errorDescription: String? {
            switch self {
            case .timedOut: return "Copilot capability discovery timed out. No provider was launched."
            case .unanswered: return "Copilot help failed or returned no valid help. Retry after checking the CLI."
            }
        }
    }

    private struct Identity: Hashable, Sendable {
        let path: String
        let resolvedPath: String
        let size: Int64
        let modified: Date?
        let inode: UInt64
        let generation: UInt64
        init(_ path: String) {
            self.path = path
            resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            modified = attributes?[.modificationDate] as? Date
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            generation = CopilotCapabilityProbe.generation(for: path)
        }
    }

    // This derived cache is the only synchronous view. It cannot initiate work.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Identity: CopilotCLICapabilities] = [:]
    nonisolated(unsafe) private static var generations: [String: UInt64] = [:]
    nonisolated private static func generation(for path: String) -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return generations[path, default: 0]
    }
    private static func store(_ value: CopilotCLICapabilities, for key: Identity) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = cache.filter { $0.key.path != key.path }
        cache[key] = value
    }
    nonisolated static func cached(executablePath: String) -> CopilotCLICapabilities? {
        let key = Identity(executablePath)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }
    nonisolated static func invalidate(executablePath: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = cache.filter { $0.key.path != executablePath }
        generations[executablePath, default: 0] &+= 1
    }

    private struct Waiter {
        let continuation: CheckedContinuation<CopilotCLICapabilities, Error>
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }
    private var flights: [Identity: Flight] = [:]

    // Diagnostic seam for deterministic concurrency regression tests.
    func waiterCount(executablePath: String) -> Int {
        flights[Identity(executablePath)]?.waiters.count ?? 0
    }

    func answer(executablePath: String, timeout: TimeInterval) async throws -> CopilotCLICapabilities {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        if let answer = Self.cached(executablePath: executablePath) { return answer }
        let key = Identity(executablePath)
        let deadline = ContinuousClock.now.advanced(by: .seconds(min(timeout, 60)))
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flights[key] == nil { flights[key] = makeFlight(for: key) }
                let timer = Task {
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    self.removeWaiter(key, id: waiterID, error: Failure.timedOut)
                }
                flights[key]?.waiters[waiterID] = Waiter(continuation: continuation, deadline: deadline, timer: timer)
            }
        } onCancel: {
            Task { await self.removeWaiter(key, id: waiterID, error: CancellationError()) }
        }
    }

    private func makeFlight(for key: Identity, waiters: [UUID: Waiter] = [:]) -> Flight {
        let id = UUID()
        let task = Task {
            let result = await query(key.path)
            self.finish(key, id: id, result: result)
        }
        return Flight(id: id, task: task, waiters: waiters)
    }

    private func removeWaiter(_ key: Identity, id: UUID, error: Error) {
        guard let waiter = flights[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: error)
        if flights[key]?.waiters.isEmpty == true {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finish(_ key: Identity, id: UUID, result: RunResult) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        // The subprocess hang breaker belongs to this flight, not its late
        // subscribers. Renew only for consumers whose original budget remains;
        // their existing timers still enforce their own absolute deadlines.
        if result.timedOut, Identity(key.path) == key {
            var remaining: [UUID: Waiter] = [:]
            for (waiterID, waiter) in flight.waiters {
                if waiter.deadline > .now { remaining[waiterID] = waiter }
                else {
                    waiter.timer.cancel()
                    waiter.continuation.resume(throwing: Failure.timedOut)
                }
            }
            if !remaining.isEmpty { flights[key] = makeFlight(for: key, waiters: remaining) }
            return
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A successful process is necessary, but empty/truncated output is not
        // evidence of supported flags. Never memoise a failed/partial response.
        let valid = result.isSuccess && !result.stdoutTruncated && (text.contains("--") || text.localizedCaseInsensitiveContains("usage:"))
            && Identity(key.path) == key
        let answer = valid ? CopilotCLICapabilities(helpText: text) : nil
        if let answer { Self.store(answer, for: key) }
        for waiter in flight.waiters.values {
            waiter.timer.cancel()
            // Timer callbacks can be queued behind this completion. The
            // subscriber's deadline still wins over a late successful answer.
            if waiter.deadline <= .now { waiter.continuation.resume(throwing: Failure.timedOut) }
            else if let answer { waiter.continuation.resume(returning: answer) }
            else { waiter.continuation.resume(throwing: result.timedOut ? Failure.timedOut : Failure.unanswered) }
        }
    }
}
