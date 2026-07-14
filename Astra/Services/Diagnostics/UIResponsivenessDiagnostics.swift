import Foundation
import ASTRALogging

/// A privacy-safe statistical view over responsiveness events already retained
/// by the normal diagnostic log stream. Values are derived only from sanitized
/// key/value fields written by `PerformanceTelemetry`.
struct UIResponsivenessEventSummary: Equatable {
    let event: String
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    let warningCount: Int
    let cacheStates: [String: Int]
}

/// A single slow interaction with its endpoint and the named phases recorded
/// under the same trace ID. This makes a support bundle actionable without
/// exposing task content.
struct UIResponsivenessSlowTrace: Equatable {
    let traceID: String
    let taskID: String
    let event: String
    let durationMilliseconds: Double
    let phases: [String]
}

struct UIResponsivenessReport: Equatable {
    let eventSummaries: [UIResponsivenessEventSummary]
    let slowestTraces: [UIResponsivenessSlowTrace]

    static let empty = UIResponsivenessReport(eventSummaries: [], slowestTraces: [])
}

/// Converts raw Performance log entries into p50/p95/max summaries. Keeping
/// the parser separate from `LogDiagnosticsService` makes percentile behavior
/// deterministic and directly regression-testable.
enum UIResponsivenessDiagnostics {
    private struct Measurement {
        let event: String
        let durationMilliseconds: Double
        let traceID: String?
        let taskID: String
        let cacheState: String?
        let level: LogLevel
    }

    static func makeReport(entries: [LogEntry]) -> UIResponsivenessReport {
        let fieldsByEntry = entries.map { entry in (entry, fields(in: entry.message)) }
        let measurements = fieldsByEntry.compactMap { entry, fields -> Measurement? in
            guard entry.category == "Performance",
                  let rawEvent = fields["event"],
                  isResponsivenessEvent(rawEvent),
                  let rawDuration = fields["duration_ms"],
                  let duration = Double(rawDuration), duration >= 0
            else { return nil }

            return Measurement(
                event: displayEvent(rawEvent, fields: fields),
                durationMilliseconds: duration,
                traceID: fields["trace_id"],
                taskID: fields["task_id"] ?? entry.taskID.map(PerformanceTelemetryFields.abbreviatedID) ?? "none",
                cacheState: fields["snapshot_cache_state"] ?? fields["cache_state"],
                level: entry.logLevel
            )
        }

        let eventSummaries = Dictionary(grouping: measurements, by: \.event)
            .map { event, samples in
                let durations = samples.map(\.durationMilliseconds).sorted()
                return UIResponsivenessEventSummary(
                    event: event,
                    sampleCount: samples.count,
                    p50Milliseconds: percentile(durations, quantile: 0.50),
                    p95Milliseconds: percentile(durations, quantile: 0.95),
                    maxMilliseconds: durations.last ?? 0,
                    warningCount: samples.filter { $0.level == .warning || $0.level == .error }.count,
                    cacheStates: Dictionary(grouping: samples.compactMap(\.cacheState), by: { $0 })
                        .mapValues(\.count)
                )
            }
            .sorted { lhs, rhs in
                if lhs.p95Milliseconds != rhs.p95Milliseconds {
                    return lhs.p95Milliseconds > rhs.p95Milliseconds
                }
                return lhs.event < rhs.event
            }

        var phasesByTrace: [String: Set<String>] = [:]
        for entryAndFields in fieldsByEntry {
            let fields = entryAndFields.1
            guard fields["event"] == "task_open_phase"
                    || fields["event"] == "task_open_apply_to_ready",
                  let traceID = fields["trace_id"],
                  let phase = fields["phase"] else { continue }
            phasesByTrace[traceID, default: []].insert(phase)
        }

        let slowestTraces = measurements
            .compactMap { measurement -> UIResponsivenessSlowTrace? in
                guard let traceID = measurement.traceID else { return nil }
                return UIResponsivenessSlowTrace(
                    traceID: traceID,
                    taskID: measurement.taskID,
                    event: measurement.event,
                    durationMilliseconds: measurement.durationMilliseconds,
                    phases: Array(phasesByTrace[traceID, default: []]).sorted()
                )
            }
            .reduce(into: [String: UIResponsivenessSlowTrace]()) { result, candidate in
                guard let existing = result[candidate.traceID] else {
                    result[candidate.traceID] = candidate
                    return
                }
                if candidate.durationMilliseconds > existing.durationMilliseconds {
                    result[candidate.traceID] = candidate
                }
            }
            .values
            .sorted { lhs, rhs in
                if lhs.durationMilliseconds != rhs.durationMilliseconds {
                    return lhs.durationMilliseconds > rhs.durationMilliseconds
                }
                return lhs.traceID < rhs.traceID
            }
            .prefix(5)

        return UIResponsivenessReport(
            eventSummaries: eventSummaries,
            slowestTraces: Array(slowestTraces)
        )
    }

    static func fields(in message: String) -> [String: String] {
        message.split(separator: " ").reduce(into: [String: String]()) { fields, component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return }
            let key = String(pair[0])
            let value = String(pair[1])
            guard !key.isEmpty, !value.isEmpty else { return }
            fields[key] = value
        }
    }

    static func isRoutineMeasurement(_ event: String) -> Bool {
        isResponsivenessEvent(event) && event != "task_selection_timeout"
    }

    private static func isResponsivenessEvent(_ event: String) -> Bool {
        event == "task_selection_timeout"
            || event.hasPrefix("task_selection_to_")
            || event.hasPrefix("screen_transition_to_")
            || event.hasPrefix("task_open_")
            || event.hasPrefix("run_finalize_")
            || event.hasPrefix("files_shelf_")
            || event.hasPrefix("chat_stream_")
            || event.hasPrefix("chat_scroll_")
    }

    private static func displayEvent(_ event: String, fields: [String: String]) -> String {
        if ["task_open_phase", "run_finalize_phase"].contains(event), let phase = fields["phase"] {
            return "\(event):\(phase)"
        }
        if event.hasPrefix("screen_transition_to_"), let destination = fields["destination"] {
            return "\(event):\(destination)"
        }
        return event
    }

    private static func percentile(_ sortedValues: [Double], quantile: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = max(0, min(sortedValues.count - 1, Int(ceil(quantile * Double(sortedValues.count))) - 1))
        return sortedValues[index]
    }
}
