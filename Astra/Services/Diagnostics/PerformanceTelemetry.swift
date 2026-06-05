import Foundation
import os

enum PerformanceTelemetry {
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

    static func log(
        _ event: String,
        durationMilliseconds: Double? = nil,
        level: LogLevel = .debug,
        fields: [String: String] = [:]
    ) {
        var parts = ["event=\(event)"]
        if let durationMilliseconds {
            parts.append(String(format: "duration_ms=%.2f", durationMilliseconds))
        }
        parts += fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let message = parts.joined(separator: " ")

        switch level {
        case .debug:
            AppLogger.debug(message, category: "Performance")
        case .info:
            AppLogger.info(message, category: "Performance")
        case .warning:
            AppLogger.warning(message, category: "Performance")
        case .error:
            AppLogger.error(message, category: "Performance")
        }
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
