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
    private var hasPendingRequestedRefresh = false
    private var historyTaskID: UUID?
    private var historyTask: AgentTask?
    private var expansionRunCount: Int = 50
    private var historyModelContext: ModelContext?
    private var historyCursor: TaskThreadHistoryCursor?
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
    private let snapshotBuilder: SnapshotBuilder?
    private let snapshotBuildExecutor = TaskThreadSnapshotBuildExecutor()

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
            historyModelContext = modelContext
            historyTaskID = task.id
            historyTask = task
            historyCursor = nil
            loadedHistoryEvents = [:]
            loadedHistoryStateAnchors = [:]
            loadedHistoryRuns = [:]
            historyTotalEventCount = 0
            historyTotalRunCount = 0
            historyLoadState = .idle
            hasEarlierHistory = false
            historyReadCountForTesting = 0
            snapshotTrigger = nil
            self.responsivenessContext?.cancel()
            pendingSnapshotRequest = nil
            requestedRefreshTask?.cancel()
            requestedRefreshTask = nil
            historyLoadTask?.cancel()
            historyLoadTask = nil
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

    private func refreshSnapshot(
        for task: AgentTask,
        preparedInput: TaskThreadSnapshotInput?,
        bypassCache: Bool
    ) {
        var fields = Self.taskFields(task)
        let responsivenessContext = responsivenessContext
        // A terminal cache key is intentionally built before the reactive
        // trigger. It uses only the task's durable revision and O(1) counts,
        // keeping repeated opens of long completed histories off the main
        // actor's event scan path.
        let cacheKey = TaskThreadSnapshotCacheKey(task: task, maxRuns: expansionRunCount)
        let applicableCacheKey = bypassCache ? nil : cacheKey
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
        } else if let historyModelContext {
            do {
                let page = try TaskThreadHistoryReader.initialPage(
                    taskID: task.id,
                    modelContext: historyModelContext
                )
                historyReadCountForTesting += 1
                mergeLatestHistoryPage(page)
                input = storageBackedInput(for: task)
                historyLoadState = .idle
            } catch {
                historyLoadState = .failed(error.localizedDescription)
                PerformanceTelemetry.log(
                    "thread_history_read_failed",
                    level: .error,
                    fields: fields.merging(["operation": "latest"], uniquingKeysWith: { _, new in new }),
                    taskID: task.id
                )
                return
            }
        } else {
            input = TaskThreadSnapshotInput(
                task: task,
                maxRuns: expansionRunCount,
                performanceFields: responsivenessContext?.fields ?? [:]
            )
        }

        let trigger = TaskThreadSnapshotTrigger(task: task, input: input)
        let resolvedTrigger = historyModelContext == nil
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
        if historyModelContext != nil {
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
        guard let modelContext = historyModelContext else {
            expandWindow(for: task)
            return
        }

        historyLoadState = .loading
        let taskID = task.id
        historyLoadTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard self?.historyTaskID == taskID else { return }
            self?.performEarlierHistoryLoad(for: task, modelContext: modelContext)
        }
    }

    private func performEarlierHistoryLoad(for task: AgentTask, modelContext: ModelContext) {
        guard historyTaskID == task.id, !Task.isCancelled else { return }
        defer {
            if historyTaskID == task.id {
                historyLoadTask = nil
            }
        }
        do {
            var initializedHistory = false
            if historyCursor == nil {
                let initialPage = try TaskThreadHistoryReader.initialPage(
                    taskID: task.id,
                    modelContext: modelContext
                )
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
                        bypassCache: true
                    )
                } else {
                    historyLoadState = .idle
                }
                return
            }
            let page = try TaskThreadHistoryReader.previousPage(
                taskID: task.id,
                before: cursor,
                modelContext: modelContext
            )
            historyReadCountForTesting += 1
            mergeEarlierHistoryPage(page)
            snapshotTrigger = nil
            refreshSnapshot(
                for: task,
                preparedInput: storageBackedInput(for: task),
                bypassCache: true
            )
        } catch {
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
        loadEarlierHistory(for: task)
    }

    private func replaceHistory(with page: TaskThreadHistoryPage) {
        loadedHistoryRuns = Dictionary(uniqueKeysWithValues: page.runs.map { ($0.id, $0) })
        loadedHistoryEvents = Dictionary(uniqueKeysWithValues: page.events.map { ($0.id, $0) })
        loadedHistoryStateAnchors = Self.stateAnchorDictionary(page.stateAnchors)
        historyTotalRunCount = page.totalRunCount
        historyTotalEventCount = page.totalEventCount
        historyCursor = page.cursor
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
        let projectedEvents = TaskThreadEventProjectionPolicy.storageEvents(
            Array(accumulatedEvents.values),
            loadedRunIDs: loadedRunIDs
        )
        let events = projectedEvents.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
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
