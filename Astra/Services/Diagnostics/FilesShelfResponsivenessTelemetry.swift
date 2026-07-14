import Foundation
import os
import ASTRACore

struct FilesShelfResponsivenessResult: Equatable {
    let event: String
    let durationMilliseconds: Double
    let fields: [String: String]
    let taskID: UUID?
}

struct FilesShelfResponsivenessTrace: Equatable {
    let traceID: String
    let source: String
    let taskID: UUID?
    let workspaceID: UUID?
    let startedAtUptimeNanoseconds: UInt64

    func result(
        event: String,
        at uptimeNanoseconds: UInt64,
        fields: [String: String] = [:]
    ) -> FilesShelfResponsivenessResult {
        FilesShelfResponsivenessResult(
            event: event,
            durationMilliseconds: Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000,
            fields: baseFields.merging(fields, uniquingKeysWith: { _, new in new }),
            taskID: taskID
        )
    }

    private var baseFields: [String: String] {
        [
            "trace_id": traceID,
            "source": source,
            "task_id": PerformanceTelemetryFields.abbreviatedID(taskID),
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(workspaceID)
        ]
    }
}

/// Correlates the Files shelf interaction with the moments users can actually
/// observe: chrome committed, first file rows available, and the requested
/// index refreshed. Paths, names, and document contents are never recorded.
@MainActor
enum FilesShelfResponsivenessTelemetry {
    private static let signposter = OSSignposter(
        subsystem: AppChannel.current.loggingSubsystem,
        category: "Performance"
    )

    private struct ActiveTrace {
        let trace: FilesShelfResponsivenessTrace
        let interval: OSSignpostIntervalState
        var chromeReady = false
        var firstResultsReady = false
    }

    private static var activeTraces: [UUID: ActiveTrace] = [:]

    static func begin(
        source: String,
        taskID: UUID?,
        workspaceID: UUID?,
        scope: UUID
    ) {
        cancel(scope: scope, reason: "superseded")
        let id = signposter.makeSignpostID()
        activeTraces[scope] = ActiveTrace(
            trace: FilesShelfResponsivenessTrace(
                traceID: AuditTrace.make("files-shelf"),
                source: source,
                taskID: taskID,
                workspaceID: workspaceID,
                startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            interval: signposter.beginInterval("files_shelf_to_index_ready", id: id)
        )
    }

    static func ensureStarted(taskID: UUID?, workspaceID: UUID?, scope: UUID) {
        guard activeTraces[scope] == nil else { return }
        begin(source: "view_appear", taskID: taskID, workspaceID: workspaceID, scope: scope)
    }

    static func chromeReady(scope: UUID) {
        guard var active = activeTraces[scope], !active.chromeReady else { return }
        active.chromeReady = true
        log(active.trace.result(event: "files_shelf_to_chrome_ready", at: DispatchTime.now().uptimeNanoseconds))
        activeTraces[scope] = active
    }

    static func firstResultsReady(
        scope: UUID,
        fileScope: String,
        cacheState: String,
        rootCount: Int,
        nodeCount: Int
    ) {
        guard var active = activeTraces[scope], !active.firstResultsReady else { return }
        active.firstResultsReady = true
        log(active.trace.result(
            event: "files_shelf_to_first_results",
            at: DispatchTime.now().uptimeNanoseconds,
            fields: scaleFields(
                fileScope: fileScope,
                cacheState: cacheState,
                rootCount: rootCount,
                nodeCount: nodeCount
            )
        ))
        activeTraces[scope] = active
    }

    static func indexReady(
        scope: UUID,
        fileScope: String,
        cacheState: String,
        rootCount: Int,
        nodeCount: Int,
        errorCount: Int,
        isTruncated: Bool
    ) {
        guard let active = activeTraces.removeValue(forKey: scope) else { return }
        signposter.endInterval("files_shelf_to_index_ready", active.interval)
        var fields = scaleFields(
            fileScope: fileScope,
            cacheState: cacheState,
            rootCount: rootCount,
            nodeCount: nodeCount
        )
        fields["error_count"] = PerformanceTelemetryFields.count(errorCount)
        fields["truncated"] = PerformanceTelemetryFields.bool(isTruncated)
        log(active.trace.result(
            event: "files_shelf_to_index_ready",
            at: DispatchTime.now().uptimeNanoseconds,
            fields: fields
        ))
    }

    static func logIndexScan(
        durationMilliseconds: Double,
        fileScope: String,
        rootCount: Int,
        nodeCount: Int,
        errorCount: Int,
        isTruncated: Bool,
        reason: String,
        taskID: UUID?
    ) {
        PerformanceTelemetry.log(
            "files_shelf_index_scan",
            durationMilliseconds: durationMilliseconds,
            level: durationMilliseconds >= 1_000 ? .warning : .info,
            fields: [
                "scope": fileScope,
                "reason": reason,
                "root_count": PerformanceTelemetryFields.count(rootCount),
                "root_count_bucket": PerformanceTelemetryFields.countBucket(rootCount),
                "node_count": PerformanceTelemetryFields.count(nodeCount),
                "node_count_bucket": PerformanceTelemetryFields.countBucket(nodeCount),
                "error_count": PerformanceTelemetryFields.count(errorCount),
                "truncated": PerformanceTelemetryFields.bool(isTruncated)
            ],
            taskID: taskID
        )
    }

    static func logPreviewLoad(
        durationMilliseconds: Double,
        kind: ShelfTextDocumentKind,
        byteCount: Int64,
        outcome: String,
        taskID: UUID?
    ) {
        PerformanceTelemetry.log(
            "files_shelf_preview_load",
            durationMilliseconds: durationMilliseconds,
            level: durationMilliseconds >= 750 ? .warning : .info,
            fields: [
                "kind": kind.rawValue,
                "byte_bucket": PerformanceTelemetryFields.byteBucket(Int(clamping: byteCount)),
                "outcome": outcome
            ],
            taskID: taskID
        )
    }

    static func cancel(scope: UUID, reason: String) {
        guard let active = activeTraces.removeValue(forKey: scope) else { return }
        signposter.endInterval("files_shelf_to_index_ready", active.interval)
        PerformanceTelemetry.log(
            "files_shelf_cancelled",
            durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(
                since: active.trace.startedAtUptimeNanoseconds
            ),
            fields: [
                "trace_id": active.trace.traceID,
                "reason": reason,
                "task_id": PerformanceTelemetryFields.abbreviatedID(active.trace.taskID),
                "workspace_id": PerformanceTelemetryFields.abbreviatedID(active.trace.workspaceID)
            ],
            taskID: active.trace.taskID
        )
    }

    static func resetForTesting() {
        for scope in Array(activeTraces.keys) {
            cancel(scope: scope, reason: "test_reset")
        }
    }

    private static func scaleFields(
        fileScope: String,
        cacheState: String,
        rootCount: Int,
        nodeCount: Int
    ) -> [String: String] {
        [
            "scope": fileScope,
            "cache_state": cacheState,
            "root_count": PerformanceTelemetryFields.count(rootCount),
            "root_count_bucket": PerformanceTelemetryFields.countBucket(rootCount),
            "node_count": PerformanceTelemetryFields.count(nodeCount),
            "node_count_bucket": PerformanceTelemetryFields.countBucket(nodeCount)
        ]
    }

    private static func log(_ result: FilesShelfResponsivenessResult) {
        let threshold: Double
        switch result.event {
        case "files_shelf_to_chrome_ready": threshold = 250
        case "files_shelf_to_first_results": threshold = 750
        default: threshold = 1_000
        }
        PerformanceTelemetry.log(
            result.event,
            durationMilliseconds: result.durationMilliseconds,
            level: result.durationMilliseconds >= threshold ? .warning : .info,
            fields: result.fields,
            taskID: result.taskID
        )
    }
}
