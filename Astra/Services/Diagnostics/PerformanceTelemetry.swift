import Foundation
import os
import ASTRAPersistence
import ASTRACore
import ASTRAModels

enum PerformanceTelemetry {
    static let uiFrameThresholdMilliseconds: Double = 8
    static let backgroundThresholdMilliseconds: Double = 20

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
        guard elapsed >= thresholdMilliseconds else { return result }

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
        guard elapsed >= thresholdMilliseconds else { return result }

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
        fields: [String: String] = [:]
    ) {
        let elapsed = elapsedMilliseconds(since: start)
        guard elapsed >= thresholdMilliseconds else { return }
        log(event, durationMilliseconds: elapsed, level: level, fields: fields)
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
    static func buildThreadSnapshot<T>(_ work: () -> T) -> T {
        interval("build_thread_snapshot", work)
    }

    @discardableResult
    static func renderTaskThread<T>(_ work: () -> T) -> T {
        interval("render_task_thread", work)
    }

    @discardableResult
    private static func interval<T>(_ name: StaticString, _ work: () -> T) -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return work()
    }
}
