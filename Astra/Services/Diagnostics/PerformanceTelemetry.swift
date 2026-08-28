import Foundation
import os
import ASTRAPersistence
import ASTRACore
import ASTRAModels

/// Totals for the samples a threshold hid, per event *and task*, over one flush
/// window.
struct PerformanceTelemetrySuppressedRollup: Equatable {
    let event: String
    /// The task the samples came from, or `nil` for the call sites that have no
    /// task in hand. Carried on the rollup rather than taken from whichever
    /// sample happened to trip the flush — see `PerformanceTelemetrySuppressedLedger`.
    let taskID: UUID?
    let count: Int
    let totalMilliseconds: Double
    let maxMilliseconds: Double
    let thresholdMilliseconds: Double
}

/// Accumulates what the thresholds throw away.
///
/// A threshold answers "is this one call slow?" — but the stall that started
/// this work was hundreds of individually-fast calls. During the worst typing
/// windows the log was *quiet*, which read as "the app was doing nothing" when
/// it meant "everything it did came in under 8 ms, several hundred times a
/// second". A quiet log has to mean no work, or it is worse than no log.
///
/// Lock-protected rather than actor-isolated because `PerformanceTelemetry` is
/// called from every thread in the app, and a diagnostic that forces a hop is
/// a diagnostic that changes what it measures. Mirrors the `NSLock` idiom used
/// by `UsageDashboardSummaryMemo` and `WildcardPatternMatcher`.
final class PerformanceTelemetrySuppressedLedger: @unchecked Sendable {
    private struct Bucket {
        var count = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
        var thresholdMilliseconds: Double = 0
    }

    /// Aggregation is per event *and* per task.
    ///
    /// Keying on the event alone folded every task's samples into one bucket,
    /// and the flush then stamped each line with the `taskID` of whichever
    /// sample happened to close the window. So a rollup covering work done for
    /// task A could be logged against task B — and the logs are read by
    /// filtering on the task, which is how this ledger gets used at all. An
    /// attribution that is confidently wrong is worse than the `nil` the
    /// unattributed call sites already report.
    private struct BucketKey: Hashable {
        let event: String
        let taskID: UUID?
    }

    private let lock = NSLock()
    private let flushInterval: TimeInterval
    private var buckets: [BucketKey: Bucket] = [:]
    /// Set by the first sample rather than at construction: the ledger is built
    /// at process start, so anchoring the window there would make the first
    /// rollup cover an arbitrary stretch of idle time.
    private var lastFlushAt: Date?

    init(flushInterval: TimeInterval) {
        self.flushInterval = flushInterval
    }

    /// Records one suppressed sample and, when the window has elapsed, hands
    /// back everything accumulated since the last flush.
    ///
    /// The caller logs the result. Doing it this way means no background timer
    /// to leak and no wakeups while the app is idle: rollups are emitted by the
    /// same activity that produced them.
    func record(
        event: String,
        taskID: UUID? = nil,
        milliseconds: Double,
        thresholdMilliseconds: Double,
        now: Date = Date()
    ) -> [PerformanceTelemetrySuppressedRollup] {
        lock.lock()
        defer { lock.unlock() }

        let key = BucketKey(event: event, taskID: taskID)
        var bucket = buckets[key] ?? Bucket()
        bucket.count += 1
        bucket.totalMilliseconds += milliseconds
        bucket.maxMilliseconds = max(bucket.maxMilliseconds, milliseconds)
        bucket.thresholdMilliseconds = thresholdMilliseconds
        buckets[key] = bucket

        guard let windowStart = lastFlushAt else {
            lastFlushAt = now
            return []
        }
        guard now.timeIntervalSince(windowStart) >= flushInterval else { return [] }
        lastFlushAt = now
        let rollups = buckets
            .map { key, bucket in
                PerformanceTelemetrySuppressedRollup(
                    event: key.event,
                    taskID: key.taskID,
                    count: bucket.count,
                    totalMilliseconds: bucket.totalMilliseconds,
                    maxMilliseconds: bucket.maxMilliseconds,
                    thresholdMilliseconds: bucket.thresholdMilliseconds
                )
            }
            // Stable order so consecutive lines are comparable by eye, and the
            // costliest event reads first. The task is the last tiebreak, so two
            // tasks doing identical work still produce a deterministic order.
            .sorted {
                (
                    $0.totalMilliseconds, $0.event, $0.taskID?.uuidString ?? ""
                ) > (
                    $1.totalMilliseconds, $1.event, $1.taskID?.uuidString ?? ""
                )
            }
        buckets.removeAll(keepingCapacity: true)
        return rollups
    }
}

enum PerformanceTelemetry {
    static let uiFrameThresholdMilliseconds: Double = 8
    static let backgroundThresholdMilliseconds: Double = 20
    /// Long enough that rollups stay rare next to real events, short enough to
    /// line up with a "the app felt slow just now" report.
    static let suppressedRollupIntervalSeconds: TimeInterval = 30

    private static let suppressedLedger = PerformanceTelemetrySuppressedLedger(
        flushInterval: suppressedRollupIntervalSeconds
    )

    /// Books a sample a threshold is about to discard, and emits the window's
    /// totals if this was the last sample in it.
    private static func noteSuppressed(
        _ event: String,
        milliseconds: Double,
        thresholdMilliseconds: Double,
        level: LogLevel,
        taskID: UUID?
    ) {
        let rollups = suppressedLedger.record(
            event: event,
            taskID: taskID,
            milliseconds: milliseconds,
            thresholdMilliseconds: thresholdMilliseconds
        )
        for rollup in rollups {
            log(
                "perf_suppressed_rollup",
                durationMilliseconds: rollup.totalMilliseconds,
                level: level,
                fields: [
                    "suppressed_event": rollup.event,
                    "suppressed_count": PerformanceTelemetryFields.count(rollup.count),
                    "max_ms": String(format: "%.2f", rollup.maxMilliseconds),
                    "mean_ms": String(
                        format: "%.2f",
                        rollup.totalMilliseconds / Double(max(rollup.count, 1))
                    ),
                    "threshold_ms": String(format: "%.2f", rollup.thresholdMilliseconds),
                    "window_s": String(format: "%.0f", suppressedRollupIntervalSeconds)
                ],
                // The rollup's own task, not this sample's. They are usually
                // the same and occasionally are not, and the time they are not
                // is a burst from one task closing another task's window.
                taskID: rollup.taskID
            )
        }
    }

    @discardableResult
    static func measure<T>(
        _ event: String,
        thresholdMilliseconds: Double = 0,
        level: LogLevel = .debug,
        fields: [String: String] = [:],
        _ work: () -> T
    ) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard elapsed >= thresholdMilliseconds else {
            noteSuppressed(
                event,
                milliseconds: elapsed,
                thresholdMilliseconds: thresholdMilliseconds,
                level: level,
                taskID: nil
            )
            return result
        }

        log(
            event,
            durationMilliseconds: elapsed,
            level: level,
            fields: fields
        )
        return result
    }

    @discardableResult
    static func measure<T>(
        _ event: String,
        thresholdMilliseconds: Double = 0,
        level: LogLevel = .debug,
        fields: [String: String] = [:],
        resultFields: (T) -> [String: String],
        _ work: () -> T
    ) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let elapsed = elapsedMilliseconds(since: start)
        guard elapsed >= thresholdMilliseconds else {
            noteSuppressed(
                event,
                milliseconds: elapsed,
                thresholdMilliseconds: thresholdMilliseconds,
                level: level,
                taskID: nil
            )
            return result
        }

        log(
            event,
            durationMilliseconds: elapsed,
            level: level,
            fields: fields.merging(resultFields(result), uniquingKeysWith: { _, new in new })
        )
        return result
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func logIfNeeded(
        _ event: String,
        start: UInt64,
        thresholdMilliseconds: Double,
        level: LogLevel = .debug,
        fields: [String: String] = [:],
        taskID: UUID? = nil
    ) {
        let elapsed = elapsedMilliseconds(since: start)
        guard elapsed >= thresholdMilliseconds else {
            noteSuppressed(
                event,
                milliseconds: elapsed,
                thresholdMilliseconds: thresholdMilliseconds,
                level: level,
                taskID: taskID
            )
            return
        }
        log(event, durationMilliseconds: elapsed, level: level, fields: fields, taskID: taskID)
    }

    static func log(
        _ event: String,
        durationMilliseconds: Double? = nil,
        level: LogLevel = .debug,
        fields: [String: String] = [:],
        taskID: UUID? = nil
    ) {
        var parts = ["event=\(event)"]
        if let durationMilliseconds {
            parts.append(String(format: "duration_ms=%.2f", durationMilliseconds))
        }
        parts += fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(PerformanceTelemetryFields.safeValue($0.value))" }
        let message = parts.joined(separator: " ")

        switch level {
        case .debug:
            AppLogger.debug(message, category: "Performance", taskID: taskID)
        case .info:
            AppLogger.info(message, category: "Performance", taskID: taskID)
        case .warning:
            AppLogger.warning(message, category: "Performance", taskID: taskID)
        case .error:
            AppLogger.error(message, category: "Performance", taskID: taskID)
        }
    }
}

enum PerformanceTelemetryFields {
    static func count(_ value: Int) -> String {
        String(value)
    }

    static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func abbreviatedID(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.prefix(8))
    }

    static func abbreviatedID(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "none" }
        return String(id.prefix(8))
    }

    static func byteBucket(_ count: Int) -> String {
        switch count {
        case 0:
            return "0"
        case 1..<1_024:
            return "1b_1kb"
        case 1_024..<10_240:
            return "1kb_10kb"
        case 10_240..<102_400:
            return "10kb_100kb"
        case 102_400..<1_048_576:
            return "100kb_1mb"
        default:
            return "1mb_plus"
        }
    }

    static func countBucket(_ count: Int) -> String {
        switch count {
        case 0:
            return "0"
        case 1..<10:
            return "1_9"
        case 10..<50:
            return "10_49"
        case 50..<200:
            return "50_199"
        case 200..<1_000:
            return "200_999"
        default:
            return "1000_plus"
        }
    }

    static func safeValue(_ value: String, maxLength: Int = 96) -> String {
        var normalized = ""
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            normalized.append(character.isWhitespace || character == "=" ? "_" : character)
        }
        let compact = normalized
        guard compact.count > maxLength else {
            return compact.isEmpty ? "empty" : compact
        }
        return String(compact.prefix(maxLength))
    }
}

enum PerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: AppChannel.current.loggingSubsystem,
        category: "Performance"
    )

    @discardableResult
    static func processStreamLine<T>(_ work: () -> T) -> T {
        interval("process_stream_line", work)
    }

    @discardableResult
    static func parseProviderStream<T>(_ work: () -> T) -> T {
        interval("parse_provider_stream", work)
    }

    @discardableResult
    static func persistProviderEvent<T>(_ work: () -> T) -> T {
        interval("persist_provider_event", work)
    }

    @discardableResult
    static func buildThreadSnapshot<T>(_ work: () throws -> T) rethrows -> T {
        try interval("build_thread_snapshot", work)
    }

    @discardableResult
    static func renderTaskThread<T>(_ work: () -> T) -> T {
        interval("render_task_thread", work)
    }

    @discardableResult
    private static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}
