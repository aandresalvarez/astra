import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Stable correlation data supplied by the task-open trace while its initial
/// snapshot is being prepared. It contains no user content and keeps the
/// snapshot pipeline independent of the UI telemetry implementation.
private final class TaskThreadResponsivenessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func performIfActive(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        operation()
    }

    func performWithState(_ operation: (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(active)
    }
}

struct TaskThreadResponsivenessContext: Sendable {
    let traceID: String
    let telemetryObserver: (@Sendable (String, Double) -> Void)?
    private let lifetime = TaskThreadResponsivenessLifetime()

    init(
        traceID: String,
        telemetryObserver: (@Sendable (String, Double) -> Void)? = nil
    ) {
        self.traceID = traceID
        self.telemetryObserver = telemetryObserver
    }

    var fields: [String: String] {
        ["trace_id": traceID]
    }

    var isActive: Bool { lifetime.isActive }

    func cancel() {
        lifetime.cancel()
    }

    func performIfActive(_ operation: ([String: String]) -> Void) {
        lifetime.performIfActive { operation(fields) }
    }

    func performWithCorrelationFields(_ operation: ([String: String]) -> Void) {
        lifetime.performWithState { operation($0 ? fields : [:]) }
    }
}

struct TaskThreadSnapshotReadiness: Equatable, Sendable {
    let taskID: UUID?
    let revision: Int

    func isReady(for taskID: UUID) -> Bool {
        self.taskID == taskID && revision > 0
    }
}

enum TaskThreadHistoryLoadState: Equatable {
    case idle
    case loading
    case failed(String)
}

@Observable @MainActor
final class TaskThreadViewModel {
    typealias SnapshotBuilder = @Sendable (
        TaskThreadSnapshotInput,
        [String: String],
        TaskThreadResponsivenessContext?
    ) async throws -> TaskThreadSnapshot

    private struct SnapshotRequest: Sendable {
        let input: TaskThreadSnapshotInput
        let trigger: TaskThreadSnapshotTrigger
        let cacheKey: TaskThreadSnapshotCacheKey?
        let taskID: UUID
        let workspaceID: UUID?
        let revision: Int
        let scheduledAt: UInt64
        let delay: TimeInterval
        let fields: [String: String]
        let responsivenessContext: TaskThreadResponsivenessContext?
        let shouldLogLiveCadence: Bool
    }

    /// Managed models are only valid while their owning SwiftData container is
    /// alive. Storage-backed work can outlive the caller that supplied a
    /// context, so keep that persistence lifetime explicit.
    private struct HistoryPersistence {
        let container: ModelContainer
        let context: ModelContext
        /// Reads run here, off the main actor. The context stays main-actor
        /// owned and is only used to flush pending writes before a read.
        let store: TaskThreadHistoryStore

        init(context: ModelContext) {
            container = context.container
            self.context = context
            store = TaskThreadHistoryStore(container: context.container)
        }
    }

    private struct DeferredHistoryApply {
        let task: AgentTask
        let generation: Date
    }

    private(set) var snapshot: TaskThreadSnapshot?
    private(set) var generatedFilePaths: [String] = []
    /// Advances only when a non-placeholder snapshot has been applied. Views use
    /// this cheap revision to distinguish the initial shell from a transcript
    /// that is ready to lay out.
    private(set) var appliedSnapshotRevision = 0
    /// The task that produced the most recently applied non-placeholder
    /// snapshot. This prevents a previous task's ready state from being used
    /// while a newly selected task is still displaying its placeholder.
    private(set) var appliedSnapshotTaskID: UUID?
    /// Cache state for the most recent snapshot refresh, exposed as a safe
    /// diagnostic dimension for task-open responsiveness traces. Set to
    /// "pending" by `reset`, then to "hit" on a cache hit or "miss"/
    /// "not_applicable" as soon as a fresh build is kicked off -- in the
    /// miss/not_applicable case this is set before the detached build
    /// actually applies its result.
    private(set) var lastSnapshotCacheState = "not_applicable"

    /// An Equatable signal that changes when a real transcript snapshot is
    /// applied, even when that snapshot produces the same layout geometry as
    /// the placeholder it replaces.
    var appliedSnapshotReadiness: TaskThreadSnapshotReadiness {
        TaskThreadSnapshotReadiness(
            taskID: appliedSnapshotTaskID,
            revision: appliedSnapshotRevision
        )
    }

    private var snapshotTrigger: TaskThreadSnapshotTrigger?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotWorkerID: UUID?
    /// Only the newest request is retained. A superseded detached CPU build may
    /// finish synchronously after cancellation, but its coordinator generation
    /// can no longer apply or disturb the single active worker reference.
    private var pendingSnapshotRequest: SnapshotRequest?
    private var generatedFilesTask: Task<Void, Never>?
    private var requestedRefreshTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    /// Single-flight worker for the latest-page read. Making the read async
    /// removed the back-pressure the synchronous block used to provide, so at
    /// most one read is in flight and at most one is queued behind it.
    private var historyReadTask: Task<Void, Never>?
    private var historyReadWorkerID: UUID?
    private var pendingHistoryRead: AgentTask?
    /// A latest-page read that landed while an explicit "load earlier messages"
    /// page was still in flight. Its rows are already merged; only the snapshot
    /// apply is held back so the earlier page owns the next transcript update.
    private var deferredHistoryApply: DeferredHistoryApply?
    /// Newest `TaskThreadHistoryInvalidation` generation this view model's
    /// loaded rows were built from. A different value means a mutation the tail
    /// read cannot see has landed.
    private var historyInvalidationToken = 0
    private var hasPendingRequestedRefresh = false
    private var historyTaskID: UUID?
    private var historyTask: AgentTask?
    private var expansionRunCount: Int = 50
    private var historyPersistence: HistoryPersistence?
    private var historyCursor: TaskThreadHistoryCursor?
    /// Newest event seen by a completed read. Independent of `historyCursor`,
    /// which walks backwards for explicit paging and must never move it.
    private var historyTailCursor: TaskThreadEventCursor?
    private var loadedHistoryEvents: [UUID: TaskEventSnapshot] = [:]
    private var loadedHistoryStateAnchors: [TaskThreadStateEventKey: TaskEventSnapshot] = [:]
    private var loadedHistoryRuns: [UUID: TaskRunSnapshotInput] = [:]
    private var historyTotalEventCount = 0
    private var historyTotalRunCount = 0
    private(set) var historyLoadState: TaskThreadHistoryLoadState = .idle
    private(set) var hasEarlierHistory = false
    private var lastSnapshotApplyAt: Date = .distantPast
    private(set) var lastSnapshotAppliedUptimeNanoseconds: UInt64?
    /// Trace identity currently attached to the initial snapshot pipeline. This
    /// is diagnostic state only; it is cleared once transcript readiness has
    /// completed so live refreshes cannot inherit a completed open trace.
    private(set) var initialSnapshotResponsivenessTraceID: String?
    private var snapshotRevision: Int = 0
    private var responsivenessContext: TaskThreadResponsivenessContext?
    private var deferredLiveSnapshotCount = 0
    private var lastLiveSnapshotTelemetryAt: Date = .distantPast
    private(set) var snapshotBuildCountForTesting = 0
    private(set) var historyReadCountForTesting = 0
    private(set) var historyTailReadCountForTesting = 0
    private(set) var historyFullReadCountForTesting = 0
    private let snapshotBuilder: SnapshotBuilder?
    private let snapshotBuildExecutor = TaskThreadSnapshotBuildExecutor()

    /// Test seam for the window between a store page being captured off the
    /// main actor and this view model applying it. That window is where
    /// production damage happens -- `AgentRuntimeWorker` coalesces chunks and
    /// finalizes runs into the main context while the read is suspended -- and
    /// it is unreachable from a test that writes, saves, and only then
    /// refreshes. Nil in production, so no suspension is added there.
    @ObservationIgnored
    var didCaptureHistoryPageForTesting: (@MainActor () async -> Void)?
    /// Test seam standing in for the pre-read main-context save so the
    /// save-failure branch is reachable. Nil in production, which routes
    /// through `WorkspacePersistenceCoordinator`.
    @ObservationIgnored
    var historyFlushResultOverrideForTesting: (@MainActor () -> Bool)?

    private static let liveSnapshotMinimumInterval: TimeInterval = 0.120
    private static var terminalSnapshotCache = TaskThreadSnapshotCache()

    init(snapshotBuilder: SnapshotBuilder? = nil) {
        self.snapshotBuilder = snapshotBuilder
    }

    func reset(
        for task: AgentTask,
        modelContext: ModelContext? = nil,
        responsivenessContext: TaskThreadResponsivenessContext? = nil
    ) {
        PerformanceTelemetry.measure(
            "chat_thread_reset",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: Self.taskFields(task)
        ) {
            expansionRunCount = 50
            historyPersistence = modelContext.map(HistoryPersistence.init)
            historyTaskID = task.id
            historyTask = task
            historyCursor = nil
            historyTailCursor = nil
            loadedHistoryEvents = [:]
            loadedHistoryStateAnchors = [:]
            loadedHistoryRuns = [:]
            historyTotalEventCount = 0
            historyTotalRunCount = 0
            historyLoadState = .idle
            hasEarlierHistory = false
            historyReadCountForTesting = 0
            historyTailReadCountForTesting = 0
            historyFullReadCountForTesting = 0
            snapshotTrigger = nil
            self.responsivenessContext?.cancel()
            pendingSnapshotRequest = nil
            requestedRefreshTask?.cancel()
            requestedRefreshTask = nil
            historyLoadTask?.cancel()
            historyLoadTask = nil
            pendingHistoryRead = nil
            deferredHistoryApply = nil
            historyInvalidationToken = TaskThreadHistoryInvalidation.token(for: task.id)
            supersedeHistoryReadWorker()
            hasPendingRequestedRefresh = false
            supersedeSnapshotWorker()
            lastSnapshotApplyAt = .distantPast
            lastSnapshotAppliedUptimeNanoseconds = nil
            initialSnapshotResponsivenessTraceID = responsivenessContext?.traceID
            appliedSnapshotRevision = 0
            appliedSnapshotTaskID = nil
            lastSnapshotCacheState = "pending"
            self.responsivenessContext = responsivenessContext
            deferredLiveSnapshotCount = 0
            lastLiveSnapshotTelemetryAt = .distantPast
            snapshot = TaskThreadSnapshot.placeholder(goal: task.goal, createdAt: task.createdAt)
            refreshSnapshot(for: task)
            refreshGeneratedFiles(folder: TaskWorkspaceAccess(task: task).taskFolder)
        }
    }

    func refreshSnapshot(for task: AgentTask) {
        refreshSnapshot(for: task, preparedInput: nil, bypassCache: false)
    }

    /// Coalesces high-frequency typed invalidations before they touch SwiftData.
    /// Direct user actions still call `refreshSnapshot` when they need an
    /// immediate projection; streaming changes use this bounded cadence.
    func requestSnapshotRefresh(for task: AgentTask) {
        hasPendingRequestedRefresh = true
        guard requestedRefreshTask == nil else { return }
        let taskID = task.id
        requestedRefreshTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.performRequestedRefresh(taskID: taskID)
        }
    }

    private func performRequestedRefresh(taskID: UUID) {
        requestedRefreshTask = nil
        guard historyTaskID == taskID,
              hasPendingRequestedRefresh,
              let historyTask,
              historyTask.id == taskID else {
            return
        }
        hasPendingRequestedRefresh = false
        refreshSnapshot(for: historyTask)
    }

    /// `inputGeneration` is the `task.updatedAt` captured before the storage
    /// read that produced `preparedInput` was issued. It is the generation the
    /// input actually describes; the live task may already be newer.
    private func refreshSnapshot(
        for task: AgentTask,
        preparedInput: TaskThreadSnapshotInput?,
        bypassCache: Bool,
        inputGeneration: Date? = nil
    ) {
        var fields = Self.taskFields(task)
        let responsivenessContext = responsivenessContext
        // A terminal cache key is intentionally built before the reactive
        // trigger. It uses only the task's durable revision and O(1) counts,
        // keeping repeated opens of long completed histories off the main
        // actor's event scan path.
        let cacheKey = TaskThreadSnapshotCacheKey(task: task, maxRuns: expansionRunCount)
        // Never cache a page read under a key claiming a generation the page
        // does not contain. The read runs across an `await`, so the completion
        // envelope and the last coalesced chunk can both land during the
        // suspension; storing that stale page under the post-completion key
        // would poison every later open of the task, because `updatedAt` -- the
        // whole key's revision term -- stops moving once a task is terminal.
        let readIsBehindLiveTask = inputGeneration.map { $0 != task.updatedAt } ?? false
        let applicableCacheKey = bypassCache || readIsBehindLiveTask ? nil : cacheKey
        if preparedInput == nil, let cacheKey = applicableCacheKey,
           let cachedSnapshot = Self.terminalSnapshotCache.snapshot(for: cacheKey) {
            snapshotRevision += 1
            pendingSnapshotRequest = nil
            supersedeSnapshotWorker()
            let cacheApplyStart = DispatchTime.now().uptimeNanoseconds
            snapshot = cachedSnapshot
            appliedSnapshotRevision += 1
            appliedSnapshotTaskID = task.id
            lastSnapshotCacheState = "hit"
            lastSnapshotApplyAt = Date()
            lastSnapshotAppliedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            hasEarlierHistory = cachedSnapshot.omittedRunCount > 0 || cachedSnapshot.omittedEventCount > 0
            if let responsivenessContext {
                PerformanceTelemetry.log(
                    "task_open_snapshot_cache_apply",
                    durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: cacheApplyStart),
                    fields: fields.merging(responsivenessContext.fields, uniquingKeysWith: { _, new in new }),
                    taskID: task.id
                )
            }
            fields.merge(Self.snapshotFields(cachedSnapshot), uniquingKeysWith: { _, new in new })
            PerformanceTelemetry.log("thread_snapshot_cache", level: .debug, fields: fields.merging([
                "cache_state": "hit"
            ], uniquingKeysWith: { _, new in new }))
            return
        }

        let inputStart = DispatchTime.now().uptimeNanoseconds
        let input: TaskThreadSnapshotInput
        if let preparedInput {
            input = preparedInput
        } else if historyPersistence != nil {
            // The storage read is the single largest main-actor block in the
            // app, so it is handed to `TaskThreadHistoryStore` and re-enters
            // here with a prepared input once it lands.
            pendingHistoryRead = task
            startHistoryReadWorkerIfNeeded()
            return
        } else {
            input = TaskThreadSnapshotInput(
                task: task,
                maxRuns: expansionRunCount,
                performanceFields: responsivenessContext?.fields ?? [:]
            )
        }

        let trigger = TaskThreadSnapshotTrigger(
            task: task,
            input: input,
            inputRevision: inputGeneration ?? task.updatedAt
        )
        let resolvedTrigger = historyPersistence == nil
            ? TaskThreadSnapshotTrigger(task: task)
            : trigger
        guard snapshotTrigger != resolvedTrigger else { return }
        snapshotTrigger = resolvedTrigger
        fields.merge(Self.triggerFields(resolvedTrigger), uniquingKeysWith: { _, new in new })
        fields.merge([
            "status": resolvedTrigger.status.rawValue,
            "latest_run_status": resolvedTrigger.latestRunStatus?.rawValue ?? "none"
        ], uniquingKeysWith: { _, new in new })

        if let responsivenessContext {
            PerformanceTelemetry.log(
                "task_open_snapshot_input_capture",
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: inputStart),
                fields: fields.merging(responsivenessContext.fields, uniquingKeysWith: { _, new in new }),
                taskID: task.id
            )
        }
        lastSnapshotCacheState = applicableCacheKey == nil ? "not_applicable" : "miss"
        fields.merge(Self.inputFields(input), uniquingKeysWith: { _, new in new })

        let isLive = resolvedTrigger.status == .running
            || resolvedTrigger.status == .queued
            || resolvedTrigger.latestRunStatus == .running
        let elapsed = Date().timeIntervalSince(lastSnapshotApplyAt)
        let minimumInterval = Self.liveSnapshotMinimumInterval
        let delay = isLive && elapsed < minimumInterval ? (minimumInterval - elapsed) : 0
        if isLive, delay > 0 {
            deferredLiveSnapshotCount += 1
        }
        let taskID = task.id
        let workspaceID = task.workspace?.id
        snapshotRevision += 1
        let revision = snapshotRevision
        let scheduledAt = DispatchTime.now().uptimeNanoseconds
        let snapshotPerformanceFields = fields
        let shouldLogLiveCadence = isLive
            && Date().timeIntervalSince(lastLiveSnapshotTelemetryAt) >= 1
        if shouldLogLiveCadence {
            lastLiveSnapshotTelemetryAt = Date()
        }
        pendingSnapshotRequest = SnapshotRequest(
            input: input,
            trigger: resolvedTrigger,
            cacheKey: applicableCacheKey,
            taskID: taskID,
            workspaceID: workspaceID,
            revision: revision,
            scheduledAt: scheduledAt,
            delay: delay,
            fields: snapshotPerformanceFields,
            responsivenessContext: responsivenessContext,
            shouldLogLiveCadence: shouldLogLiveCadence
        )
        // A request that arrives during either the throttle sleep or detached
        // CPU build must not wait behind obsolete work. Cancellation prevents
        // the old generation from applying, while the identity guard in the
        // worker's cleanup prevents it from clearing this replacement.
        supersedeSnapshotWorker()
        startSnapshotWorkerIfNeeded()
    }

    private func supersedeSnapshotWorker() {
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotWorkerID = nil
    }

    private func startSnapshotWorkerIfNeeded() {
        guard snapshotTask == nil else { return }
        let workerID = UUID()
        snapshotWorkerID = workerID
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.takePendingSnapshotRequest() {
                if request.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(request.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { break }
                request.responsivenessContext?.performIfActive { traceFields in
                    let queueWait = PerformanceTelemetry.elapsedMilliseconds(since: request.scheduledAt)
                    PerformanceTelemetry.log(
                        "task_open_snapshot_queue_wait",
                        durationMilliseconds: queueWait,
                        fields: request.fields.merging(traceFields, uniquingKeysWith: { _, new in new }),
                        taskID: request.taskID
                    )
                    request.responsivenessContext?.telemetryObserver?("task_open_snapshot_queue_wait", queueWait)
                }
                let buildStartedAt = DispatchTime.now().uptimeNanoseconds
                self.snapshotBuildCountForTesting += 1
                let builtSnapshot: TaskThreadSnapshot
                do {
                    if let snapshotBuilder = self.snapshotBuilder {
                        builtSnapshot = try await snapshotBuilder(
                            request.input,
                            request.fields,
                            request.responsivenessContext
                        )
                    } else {
                        // Capture executor admission immediately before the
                        // actor await. Request scheduling and live throttling
                        // belong to task_open_snapshot_queue_wait instead.
                        let executorAdmissionStartedAt = DispatchTime.now().uptimeNanoseconds
                        request.responsivenessContext?.telemetryObserver?(
                            "thread_snapshot_executor_admission_started",
                            0
                        )
                        builtSnapshot = try await self.snapshotBuildExecutor.build(
                            input: request.input,
                            fields: request.fields,
                            responsivenessContext: request.responsivenessContext,
                            admittedAt: executorAdmissionStartedAt
                        )
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if self.historyLoadState == .loading {
                        self.historyLoadState = .failed(error.localizedDescription)
                    }
                    PerformanceTelemetry.log(
                        "thread_snapshot_build_failed",
                        level: .error,
                        fields: request.fields.merging(["error": String(describing: error)], uniquingKeysWith: { _, new in new }),
                        taskID: request.taskID
                    )
                    continue
                }
                let buildCompletedAt = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled else { break }
                self.applySnapshotIfCurrent(
                    builtSnapshot,
                    request: request,
                    buildStartedAt: buildStartedAt,
                    buildCompletedAt: buildCompletedAt
                )
            }
            guard self.snapshotWorkerID == workerID else { return }
            self.snapshotTask = nil
            self.snapshotWorkerID = nil
            // A request can arrive after the loop observes an empty slot but
            // before this task clears itself. Recheck to avoid stranding it.
            if self.pendingSnapshotRequest != nil {
                self.startSnapshotWorkerIfNeeded()
            }
        }
    }

    private func takePendingSnapshotRequest() -> SnapshotRequest? {
        defer { pendingSnapshotRequest = nil }
        return pendingSnapshotRequest
    }

    private func applySnapshotIfCurrent(
        _ builtSnapshot: TaskThreadSnapshot,
        request: SnapshotRequest,
        buildStartedAt: UInt64,
        buildCompletedAt: UInt64
    ) {
        guard request.revision == snapshotRevision else { return }
        request.responsivenessContext?.performIfActive { traceFields in
            PerformanceTelemetry.log(
                "task_open_snapshot_main_actor_apply_wait",
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: buildCompletedAt),
                fields: request.fields.merging(traceFields, uniquingKeysWith: { _, new in new }),
                taskID: request.taskID
            )
        }
        let applyStartedAt = DispatchTime.now().uptimeNanoseconds
        snapshot = builtSnapshot
        if historyLoadState == .loading {
            historyLoadState = .idle
        }
        appliedSnapshotRevision += 1
        appliedSnapshotTaskID = request.taskID
        if let cacheKey = request.cacheKey {
            Self.terminalSnapshotCache.store(builtSnapshot, for: cacheKey)
        }
        lastSnapshotApplyAt = Date()
        lastSnapshotAppliedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        request.responsivenessContext?.performIfActive { traceFields in
            PerformanceTelemetry.log(
                "task_open_snapshot_apply",
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: applyStartedAt),
                fields: request.fields.merging(traceFields, uniquingKeysWith: { _, new in new }),
                taskID: request.taskID
            )
        }
        if request.shouldLogLiveCadence {
            PerformanceTelemetry.log(
                "chat_stream_snapshot_cadence",
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: buildStartedAt),
                level: .debug,
                fields: request.fields.merging([
                    "throttle_delay_ms": String(format: "%.2f", request.delay * 1_000),
                    "deferred_snapshot_count": PerformanceTelemetryFields.count(deferredLiveSnapshotCount)
                ], uniquingKeysWith: { _, new in new }),
                taskID: request.taskID
            )
            deferredLiveSnapshotCount = 0
        }
        Self.logSnapshotState(
            snapshot: builtSnapshot,
            trigger: request.trigger,
            taskID: request.taskID,
            workspaceID: request.workspaceID
        )
    }

    /// Ends correlation for the initial task-open snapshot after the view has
    /// emitted transcript readiness. Subsequent streaming refreshes retain
    /// their own bounded cadence telemetry but are not misattributed to open.
    func completeInitialResponsivenessTrace(for taskID: UUID) {
        guard appliedSnapshotTaskID == taskID else { return }
        responsivenessContext?.cancel()
        responsivenessContext = nil
        initialSnapshotResponsivenessTraceID = nil
    }

    /// Ends only telemetry correlation when an open trace times out or its view
    /// disappears. The user-visible snapshot build must continue to completion.
    func cancelInitialResponsivenessCorrelation(for taskID: UUID) {
        guard snapshotTrigger?.taskID == taskID, responsivenessContext != nil else { return }
        responsivenessContext?.cancel()
        responsivenessContext = nil
        initialSnapshotResponsivenessTraceID = nil
    }

    static func resetSnapshotCacheForTesting() {
        terminalSnapshotCache.removeAll()
    }

    static var snapshotCacheStatsForTesting: TaskThreadSnapshotCache.Stats {
        terminalSnapshotCache.stats
    }

    /// Awaits coordinator work by task identity rather than elapsed wall time.
    /// Parallel suites can temporarily saturate the main actor without turning
    /// functional assertions into timeout failures.
    func waitForPendingWorkForTesting() async {
        while true {
            if let requestedRefreshTask {
                await requestedRefreshTask.value
                continue
            }
            if let historyLoadTask {
                await historyLoadTask.value
                continue
            }
            if let historyReadTask {
                await historyReadTask.value
                continue
            }
            if let snapshotTask {
                await snapshotTask.value
                continue
            }
            return
        }
    }

    /// Awaits only the latest-page reader. `waitForPendingWorkForTesting` also
    /// awaits `historyLoadTask`, which deadlocks when the caller is running
    /// inside that task -- exactly the interleaving these tests reproduce.
    func waitForHistoryReadForTesting() async {
        while let historyReadTask {
            await historyReadTask.value
        }
    }

    private static func taskFields(_ task: AgentTask) -> [String: String] {
        [
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(task.workspace?.id),
            "status": task.status.rawValue
        ]
    }

    private static func triggerFields(_ trigger: TaskThreadSnapshotTrigger) -> [String: String] {
        [
            "event_count": PerformanceTelemetryFields.count(trigger.eventCount),
            "visible_event_count": PerformanceTelemetryFields.count(trigger.visibleEventCount),
            "run_count": PerformanceTelemetryFields.count(trigger.runCount),
            "latest_run_output_bucket": PerformanceTelemetryFields.count(trigger.latestRunOutputBucket),
            "latest_run_output_bytes": PerformanceTelemetryFields.count(trigger.latestRunOutputCount),
            "latest_run_output_byte_bucket": PerformanceTelemetryFields.byteBucket(trigger.latestRunOutputCount)
        ]
    }

    private static func inputFields(_ input: TaskThreadSnapshotInput) -> [String: String] {
        [
            "snapshot_input_events": PerformanceTelemetryFields.count(input.events.count),
            "snapshot_input_runs": PerformanceTelemetryFields.count(input.runs.count),
            "omitted_events": PerformanceTelemetryFields.count(input.omittedEventCount),
            "omitted_runs": PerformanceTelemetryFields.count(input.omittedRunCount)
        ]
    }

    private static func snapshotFields(_ snapshot: TaskThreadSnapshot) -> [String: String] {
        [
            "snapshot_input_events": PerformanceTelemetryFields.count(snapshot.sortedEvents.count),
            "snapshot_input_runs": PerformanceTelemetryFields.count(snapshot.sortedRuns.count),
            "omitted_events": PerformanceTelemetryFields.count(snapshot.omittedEventCount),
            "omitted_runs": PerformanceTelemetryFields.count(snapshot.omittedRunCount),
            "conversation_item_count": PerformanceTelemetryFields.count(snapshot.conversationItems.count)
        ]
    }

    func expandWindow(for task: AgentTask) {
        if historyPersistence != nil {
            loadEarlierHistory(for: task)
            return
        }
        guard snapshot?.omittedRunCount ?? 0 > 0 else { return }
        expansionRunCount += 50
        snapshotTrigger = nil
        refreshSnapshot(for: task)
    }

    func loadEarlierHistory(for task: AgentTask) {
        guard historyLoadState != .loading else { return }
        guard let store = historyPersistence?.store else {
            expandWindow(for: task)
            return
        }

        historyLoadState = .loading
        let taskID = task.id
        historyLoadTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard self?.historyTaskID == taskID else { return }
            await self?.performEarlierHistoryLoad(for: task, store: store)
        }
    }

    private func performEarlierHistoryLoad(
        for task: AgentTask,
        store: TaskThreadHistoryStore
    ) async {
        guard historyTaskID == task.id, !Task.isCancelled else { return }
        defer {
            if historyTaskID == task.id {
                historyLoadTask = nil
                // This load owned `historyLoadState` and the view's scroll
                // anchor, so any latest-page read that landed inside it was
                // held back. Release it now that the earlier page has merged.
                flushDeferredHistoryApply()
            }
        }
        do {
            var initializedHistory = false
            var generation = task.updatedAt
            if historyCursor == nil {
                guard flushPendingHistoryWrites() else {
                    reportHistoryFlushFailure(for: task, operation: "earlier")
                    return
                }
                let initialPage = try await store.initialPage(taskID: task.id)
                await notifyHistoryPageCapturedForTesting()
                guard isCurrentHistoryRead(task.id) else { return }
                historyReadCountForTesting += 1
                replaceHistory(with: initialPage)
                initializedHistory = true
            }
            guard let cursor = historyCursor, cursor.hasEarlierHistory else {
                hasEarlierHistory = false
                if initializedHistory {
                    snapshotTrigger = nil
                    refreshSnapshot(
                        for: task,
                        preparedInput: storageBackedInput(for: task),
                        bypassCache: true,
                        inputGeneration: generation
                    )
                } else {
                    historyLoadState = .idle
                }
                return
            }
            generation = task.updatedAt
            guard flushPendingHistoryWrites() else {
                reportHistoryFlushFailure(for: task, operation: "earlier")
                return
            }
            let page = try await store.previousPage(taskID: task.id, before: cursor)
            await notifyHistoryPageCapturedForTesting()
            guard isCurrentHistoryRead(task.id) else { return }
            historyReadCountForTesting += 1
            mergeEarlierHistoryPage(page)
            snapshotTrigger = nil
            refreshSnapshot(
                for: task,
                preparedInput: storageBackedInput(for: task),
                bypassCache: true,
                inputGeneration: generation
            )
        } catch {
            guard historyTaskID == task.id else { return }
            historyLoadState = .failed(error.localizedDescription)
            AppLogger.error(
                "Could not load earlier task history: \(error.localizedDescription)",
                category: "UI"
            )
        }
    }

    func retryEarlierHistory(for task: AgentTask) {
        guard case .failed = historyLoadState else { return }
        historyLoadState = .idle
        guard hasEarlierHistory else {
            // The failure can come from the latest-page read (a failed pre-read
            // flush freezes the transcript with no earlier page involved), so
            // Retry must re-issue that read rather than no-op.
            refreshSnapshot(for: task, preparedInput: nil, bypassCache: true)
            return
        }
        loadEarlierHistory(for: task)
    }

    private func supersedeHistoryReadWorker() {
        historyReadTask?.cancel()
        historyReadTask = nil
        historyReadWorkerID = nil
    }

    private func startHistoryReadWorkerIfNeeded() {
        guard historyReadTask == nil else { return }
        let workerID = UUID()
        historyReadWorkerID = workerID
        historyReadTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let task = self.takePendingHistoryRead() {
                await self.readHistory(for: task)
            }
            guard self.historyReadWorkerID == workerID else { return }
            self.historyReadTask = nil
            self.historyReadWorkerID = nil
            // A refresh can arrive after the loop observes an empty slot but
            // before this task clears itself. Recheck to avoid stranding it.
            if self.pendingHistoryRead != nil {
                self.startHistoryReadWorkerIfNeeded()
            }
        }
    }

    private func takePendingHistoryRead() -> AgentTask? {
        defer { pendingHistoryRead = nil }
        return pendingHistoryRead
    }

    /// Streaming appends dominate transcript invalidation, so read only the rows
    /// at or after the newest one already loaded and pay for a full page only
    /// when that tail cannot account for every change. Both reads run on
    /// `TaskThreadHistoryStore`; only the merge and the re-entry are main-actor.
    private func readHistory(for task: AgentTask) async {
        guard let store = historyPersistence?.store, historyTaskID == task.id else { return }
        let taskID = task.id
        // A mutation the tail read provably cannot observe (see
        // `TaskThreadHistoryInvalidation`) disqualifies the tail for one cycle
        // and makes the accumulated rows untrustworthy, not just incomplete.
        let invalidationToken = TaskThreadHistoryInvalidation.token(for: taskID)
        let tailIsTrusted = invalidationToken == historyInvalidationToken
        do {
            if tailIsTrusted, let cursor = historyTailCursor, historyCursor != nil {
                // Captured before the flush: writes that land from here on are
                // not guaranteed to be in the page this read returns.
                let generation = task.updatedAt
                guard flushPendingHistoryWrites() else {
                    reportHistoryFlushFailure(for: task, operation: "latest")
                    return
                }
                let tail = try await store.tailPage(taskID: taskID, since: cursor)
                await notifyHistoryPageCapturedForTesting()
                guard isCurrentHistoryRead(taskID) else { return }
                historyTailReadCountForTesting += 1
                if applyTailPage(tail) {
                    historyReadCountForTesting += 1
                    applyHistoryRead(for: task, generation: generation)
                    return
                }
            }
            let generation = task.updatedAt
            guard flushPendingHistoryWrites() else {
                reportHistoryFlushFailure(for: task, operation: "latest")
                return
            }
            let page = try await store.initialPage(taskID: taskID)
            await notifyHistoryPageCapturedForTesting()
            guard isCurrentHistoryRead(taskID) else { return }
            historyFullReadCountForTesting += 1
            historyReadCountForTesting += 1
            if tailIsTrusted {
                mergeLatestHistoryPage(page)
            } else {
                // An announced mutation deleted rows this view model still
                // holds. Merging would keep rendering them, so take the page as
                // authoritative -- the same replace-on-shrink the full-read path
                // used to reach by counting.
                replaceHistory(with: page)
                // Such a mutation can leave every trigger field identical (a
                // one-row compaction swaps a deleted row for a backdated
                // summary and moves no count and no revision), so the rebuilt
                // page must not be deduped away.
                snapshotTrigger = nil
            }
            historyInvalidationToken = invalidationToken
            applyHistoryRead(for: task, generation: generation)
        } catch {
            guard isCurrentHistoryRead(taskID) else { return }
            historyLoadState = .failed(error.localizedDescription)
            PerformanceTelemetry.log(
                "thread_history_read_failed",
                level: .error,
                fields: Self.taskFields(task).merging(
                    ["operation": "latest"],
                    uniquingKeysWith: { _, new in new }
                ),
                taskID: taskID
            )
        }
    }

    /// A task switch or a `reset` while a page is in flight must not let the
    /// previous task's rows reach the transcript.
    private func isCurrentHistoryRead(_ taskID: UUID) -> Bool {
        historyTaskID == taskID && !Task.isCancelled
    }

    /// `generation` is the `task.updatedAt` captured before the read was
    /// issued, i.e. the revision the merged rows describe. The live task can
    /// already be newer, which is what makes it unsafe to cache this snapshot
    /// or to stamp the trigger with the live revision.
    private func applyHistoryRead(for task: AgentTask, generation: Date) {
        // An explicit "load earlier messages" page owns `historyLoadState` and,
        // through the snapshot it eventually applies, the view's scroll anchor.
        // A streaming read that lands inside that window has already merged its
        // rows, so hold the apply back instead of reverting the spinner and
        // consuming the anchor before the earlier page exists.
        guard historyLoadTask == nil else {
            deferredHistoryApply = DeferredHistoryApply(task: task, generation: generation)
            return
        }
        PerformanceTelemetry.measure(
            "thread_history_apply",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: Self.taskFields(task)
        ) {
            historyLoadState = .idle
            refreshSnapshot(
                for: task,
                preparedInput: storageBackedInput(for: task),
                bypassCache: false,
                inputGeneration: generation
            )
        }
    }

    private func flushDeferredHistoryApply() {
        guard let deferred = deferredHistoryApply else { return }
        deferredHistoryApply = nil
        guard historyTaskID == deferred.task.id else { return }
        // A failure raised by the load that owned this window has to stay
        // visible. The deferred rows are already merged, so the next successful
        // read renders them.
        if case .failed = historyLoadState { return }
        applyHistoryRead(for: deferred.task, generation: deferred.generation)
    }

    private func notifyHistoryPageCapturedForTesting() async {
        guard let hook = didCaptureHistoryPageForTesting else { return }
        await hook()
    }

    /// The store reads the persistent file, but streaming coalesces
    /// `TaskEvent.payload` into the main context and never saves it
    /// (`AgentEventRecorder`). Without this flush the newest chunk stays
    /// invisible to the read and the transcript freezes one chunk behind.
    ///
    /// Returns whether the store is safe to read. A failed save is not a
    /// cosmetic miss: the read would serve pre-failure rows whose count matches
    /// the equally stale `historyTotalEventCount`, so the tail invariant accepts
    /// them and the transcript freezes mid-sentence with no error.
    private func flushPendingHistoryWrites() -> Bool {
        if let override = historyFlushResultOverrideForTesting { return override() }
        guard let persistence = historyPersistence, persistence.context.hasChanges else { return true }
        var didSave = false
        PerformanceTelemetry.measure(
            "thread_history_pre_read_save",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: ["task_id": PerformanceTelemetryFields.abbreviatedID(historyTaskID)]
        ) {
            // Deliberately no auto-export: this runs once per transcript
            // invalidation, and the workspace JSON mirror is written by the
            // run-finalize save that supersedes these rows anyway.
            didSave = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                modelContext: persistence.context,
                taskID: historyTaskID,
                auditFields: ["operation": "thread_history_pre_read_save"]
            )
        }
        return didSave
    }

    private func reportHistoryFlushFailure(for task: AgentTask, operation: String) {
        guard historyTaskID == task.id else { return }
        historyLoadState = .failed("The transcript could not be saved before reading it.")
        PerformanceTelemetry.log(
            "thread_history_read_failed",
            level: .error,
            fields: Self.taskFields(task).merging(
                ["operation": operation, "reason": "pre_read_save_failed"],
                uniquingKeysWith: { _, new in new }
            ),
            taskID: task.id
        )
    }

    /// Applies an incremental tail read, or reports that it cannot be trusted
    /// so the caller re-reads the full page.
    private func applyTailPage(_ tail: TaskThreadHistoryTailPage) -> Bool {
        guard !tail.overflowed, tail.totalRunCount >= loadedHistoryRuns.count else { return false }
        let appended = tail.events.reduce(0) { $0 + (loadedHistoryEvents[$1.id] == nil ? 1 : 0) }
        // Backdated inserts and deletions are invisible to a tail read. What
        // this proves is narrower than "the tail observed every change": it
        // proves the authoritative event count moved by exactly the number of
        // rows the tail brought back, so any mutation with a *net* effect on
        // that count is caught. Relaxing it to `>=` would let a plain deletion
        // strand deleted rows. Mutations that net to zero -- a delete paired
        // with a backdated insert, i.e. `AgentEventCompactor` -- are invisible
        // to any count and are handled by `TaskThreadHistoryInvalidation`
        // instead, which `readHistory` consults before choosing this path.
        guard tail.totalEventCount == historyTotalEventCount + appended else { return false }
        for event in tail.events { loadedHistoryEvents[event.id] = event }
        // A refreshed anchor arrives as an ordinary tail row. Merge (never
        // replace) so anchors the tail page never refetches are retained.
        mergeStateAnchors(tail.events.filter { TaskThreadStateEventPolicy.contains($0.type) })
        for run in tail.runs { loadedHistoryRuns[run.id] = run }
        historyTotalRunCount = tail.totalRunCount
        historyTotalEventCount = tail.totalEventCount
        advanceTailCursor(with: tail.events)
        historyCursor = TaskThreadHistoryCursor(
            run: historyCursor?.run,
            event: historyCursor?.event,
            hasEarlierRuns: tail.totalRunCount > loadedHistoryRuns.count,
            hasEarlierEvents: tail.totalEventCount > loadedHistoryEvents.count
        )
        hasEarlierHistory = historyCursor?.hasEarlierHistory == true
        return true
    }

    private func advanceTailCursor(with events: [TaskEventSnapshot]) {
        for event in events {
            guard let current = historyTailCursor else {
                historyTailCursor = TaskThreadEventCursor(timestamp: event.timestamp, id: event.id)
                continue
            }
            let isLater = event.timestamp == current.timestamp
                ? event.id.uuidString > current.id.uuidString
                : event.timestamp > current.timestamp
            if isLater {
                historyTailCursor = TaskThreadEventCursor(timestamp: event.timestamp, id: event.id)
            }
        }
    }

    private func replaceHistory(with page: TaskThreadHistoryPage) {
        loadedHistoryRuns = Dictionary(uniqueKeysWithValues: page.runs.map { ($0.id, $0) })
        loadedHistoryEvents = Dictionary(uniqueKeysWithValues: page.events.map { ($0.id, $0) })
        loadedHistoryStateAnchors = Self.stateAnchorDictionary(page.stateAnchors)
        historyTotalRunCount = page.totalRunCount
        historyTotalEventCount = page.totalEventCount
        historyCursor = page.cursor
        // `latestEvents` sorts descending, so the first row is the newest. This
        // is a reset, not an advance: the discarded pages may have held rows
        // that no longer exist.
        historyTailCursor = page.events.first.map {
            TaskThreadEventCursor(timestamp: $0.timestamp, id: $0.id)
        }
        hasEarlierHistory = page.cursor.hasEarlierHistory
    }

    private func mergeLatestHistoryPage(_ page: TaskThreadHistoryPage) {
        if loadedHistoryRuns.isEmpty && loadedHistoryEvents.isEmpty {
            replaceHistory(with: page)
            return
        }
        if page.totalRunCount < loadedHistoryRuns.count || page.totalEventCount < loadedHistoryEvents.count {
            // Compaction or deletion invalidated accumulated pages. Prefer an
            // accurate latest page over retaining projections of deleted rows.
            replaceHistory(with: page)
            return
        }
        guard let currentCursor = historyCursor else {
            replaceHistory(with: page)
            return
        }
        for run in page.runs { loadedHistoryRuns[run.id] = run }
        for event in page.events { loadedHistoryEvents[event.id] = event }
        replaceLatestStateAnchors(with: page.stateAnchors, refreshedRuns: page.runs)
        historyTotalRunCount = page.totalRunCount
        historyTotalEventCount = page.totalEventCount
        advanceTailCursor(with: page.events)
        historyCursor = TaskThreadHistoryCursor(
            run: currentCursor.run,
            event: currentCursor.event,
            hasEarlierRuns: page.totalRunCount > loadedHistoryRuns.count,
            hasEarlierEvents: page.totalEventCount > loadedHistoryEvents.count
        )
        hasEarlierHistory = historyCursor?.hasEarlierHistory == true
    }

    private func mergeEarlierHistoryPage(_ page: TaskThreadHistoryPage) {
        for run in page.runs { loadedHistoryRuns[run.id] = run }
        for event in page.events { loadedHistoryEvents[event.id] = event }
        mergeStateAnchors(page.stateAnchors)
        historyTotalRunCount = page.totalRunCount
        historyTotalEventCount = page.totalEventCount
        let previousCursor = historyCursor
        historyCursor = TaskThreadHistoryCursor(
            run: page.cursor.run ?? previousCursor?.run,
            event: page.cursor.event ?? previousCursor?.event,
            hasEarlierRuns: page.cursor.hasEarlierRuns,
            hasEarlierEvents: page.cursor.hasEarlierEvents
        )
        hasEarlierHistory = historyCursor?.hasEarlierHistory == true
    }

    private func storageBackedInput(for task: AgentTask) -> TaskThreadSnapshotInput {
        let anchorEvents = Dictionary(uniqueKeysWithValues: loadedHistoryStateAnchors.values.map { ($0.id, $0) })
        let accumulatedEvents = loadedHistoryEvents.merging(anchorEvents) { pageEvent, _ in
            pageEvent
        }
        let loadedRunIDs = Set(loadedHistoryRuns.keys)
        let chronologicalEvents = accumulatedEvents.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // storageEvents caps tool.result events per run by keeping the last
        // ones it sees, so the input must already be chronological or the cap
        // keeps arbitrary (dictionary-ordered) results instead of the newest.
        let events = TaskThreadEventProjectionPolicy.storageEvents(
            chronologicalEvents,
            loadedRunIDs: loadedRunIDs
        )
        let runs = loadedHistoryRuns.values.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let omittedEventCount = max(0, historyTotalEventCount - events.count)
        let omittedRunCount = max(0, historyTotalRunCount - runs.count)
        return TaskThreadSnapshotInput(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: runs,
            totalEventCount: historyTotalEventCount,
            omittedEventCount: omittedEventCount,
            totalRunCount: historyTotalRunCount,
            omittedRunCount: omittedRunCount
        )
    }

    private static func stateAnchorDictionary(
        _ anchors: [TaskEventSnapshot]
    ) -> [TaskThreadStateEventKey: TaskEventSnapshot] {
        Dictionary(anchors.map { (TaskThreadStateEventKey(event: $0), $0) }) { current, candidate in
            Self.isLaterStateAnchor(candidate, than: current) ? candidate : current
        }
    }

    private func replaceLatestStateAnchors(
        with anchors: [TaskEventSnapshot],
        refreshedRuns: [TaskRunSnapshotInput]
    ) {
        let refreshedRunIDs = Set(refreshedRuns.map(\.id))
        loadedHistoryStateAnchors = loadedHistoryStateAnchors.filter { key, _ in
            guard let runID = key.runID else { return false }
            return !refreshedRunIDs.contains(runID)
        }
        mergeStateAnchors(anchors)
    }

    private func mergeStateAnchors(_ anchors: [TaskEventSnapshot]) {
        for anchor in anchors {
            let key = TaskThreadStateEventKey(event: anchor)
            if let current = loadedHistoryStateAnchors[key],
               !Self.isLaterStateAnchor(anchor, than: current) {
                continue
            }
            loadedHistoryStateAnchors[key] = anchor
        }
    }

    private static func isLaterStateAnchor(
        _ candidate: TaskEventSnapshot,
        than current: TaskEventSnapshot
    ) -> Bool {
        if candidate.timestamp != current.timestamp {
            return candidate.timestamp > current.timestamp
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    func refreshGeneratedFiles(folder: String) {
        generatedFilesTask?.cancel()

        guard !folder.isEmpty else {
            generatedFilePaths = []
            return
        }

        generatedFilesTask = Task { [weak self] in
            let paths = await TaskGeneratedFiles.filesAsync(in: folder)
            guard !Task.isCancelled else { return }
            self?.generatedFilePaths = paths
        }
    }

    func cancelGeneratedFilesRefresh() {
        generatedFilesTask?.cancel()
        generatedFilesTask = nil
    }

    private static func logSnapshotState(
        snapshot: TaskThreadSnapshot,
        trigger: TaskThreadSnapshotTrigger,
        taskID: UUID,
        workspaceID: UUID?
    ) {
        let agentResponseCount = snapshot.conversationItems.filter { item in
            if case .agentResponse = item { return true }
            return false
        }.count
        let userMessageCount = snapshot.conversationItems.filter { item in
            if case .userMessage = item { return true }
            return false
        }.count
        let blankReason = blankReason(
            snapshot: snapshot,
            trigger: trigger,
            agentResponseCount: agentResponseCount
        )
        let level: LogLevel = blankReason == "has_visible_response" || trigger.status == .running || trigger.status == .queued
            ? .debug
            : .warning
        AppLogger.audit(.threadSnapshotBuilt, category: "UI", taskID: taskID, fields: [
            "status": trigger.status.rawValue,
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(workspaceID),
            "event_count": String(trigger.eventCount),
            "visible_event_count": String(trigger.visibleEventCount),
            "run_count": String(trigger.runCount),
            "latest_run_output_bucket": String(trigger.latestRunOutputBucket),
            "snapshot_event_count": String(snapshot.sortedEvents.count),
            "snapshot_run_count": String(snapshot.sortedRuns.count),
            "omitted_events": String(snapshot.omittedEventCount),
            "omitted_runs": String(snapshot.omittedRunCount),
            "conversation_item_count": String(snapshot.conversationItems.count),
            "agent_response_count": String(agentResponseCount),
            "user_message_count": String(userMessageCount),
            "latest_run_status": snapshot.latestRun?.status.rawValue ?? "none",
            "latest_run_output_bytes": String(trigger.latestRunOutputCount),
            "blank_reason": blankReason
        ], level: level)
    }

    private static func blankReason(
        snapshot: TaskThreadSnapshot,
        trigger: TaskThreadSnapshotTrigger,
        agentResponseCount: Int
    ) -> String {
        if agentResponseCount > 0 {
            return "has_visible_response"
        }
        if trigger.runCount == 0 {
            return "no_runs"
        }
        if snapshot.sortedRuns.contains(where: { !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "output_present_but_not_visible"
        }
        if snapshot.sortedEvents.contains(where: { $0.type == "agent.response" }) {
            return "response_events_present_but_not_visible"
        }
        if trigger.status == .running || trigger.status == .queued {
            return "run_in_progress"
        }
        return "terminal_without_visible_response"
    }
}
