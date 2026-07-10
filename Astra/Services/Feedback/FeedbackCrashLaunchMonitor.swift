import Foundation
import ASTRAModels
import ASTRACore

/// Process-global next-launch scan. The first feature launch establishes a
/// channel-specific boundary and never offers historical diagnostics.
@MainActor
final class FeedbackCrashLaunchMonitor {
    static let shared = FeedbackCrashLaunchMonitor()

    private var didScan = false
    private let channelDisplayName: String
    private let now: @Sendable () -> Date
    private let scan: @Sendable (DateInterval, String) throws -> [CrashReportSummary]
    private let readBoundary: () -> Any?
    private let writeBoundaryValue: (Any?) -> Void

    init(
        defaults: UserDefaults = .standard,
        channel: AppChannel = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        readBoundary: (() -> Any?)? = nil,
        writeBoundaryValue: ((Any?) -> Void)? = nil,
        scan: @escaping @Sendable (DateInterval, String) throws -> [CrashReportSummary] = {
            interval, displayName in
            CrashDiagnosticsService.reports(
                limit: Int.max,
                modifiedIn: interval,
                prefixes: [displayName]
            ).filter { $0.modifiedAt > interval.start && $0.modifiedAt <= interval.end }
        }
    ) {
        let key = "\(AppStorageKeys.feedbackCrashScanWatermarkPrefix).\(channel.rawValue)"
        channelDisplayName = channel.displayName
        self.now = now
        self.scan = scan
        let storageKey = key
        self.readBoundary = readBoundary ?? { defaults.object(forKey: storageKey) }
        self.writeBoundaryValue = writeBoundaryValue ?? { value in
            if let value {
                defaults.set(value, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }
    }

    func claimNextOffer(
        using service: FeedbackCrashOfferService,
        recoverableReportIDs: Set<UUID> = []
    ) async -> FeedbackCrashOffer? {
        guard !didScan else { return nil }
        didScan = true
        let boundary = now()
        guard let stored = readBoundary() else {
            guard commitBoundary(boundary, replacing: nil) else {
                AppLogger.error("Feedback crash watermark baseline was not durable", category: "Diagnostics")
                return nil
            }
            return nil
        }
        guard let seconds = stored as? NSNumber else {
            AppLogger.error("Feedback crash watermark is unreadable; prompt suppressed", category: "Diagnostics")
            return nil
        }
        let previous = Date(timeIntervalSince1970: seconds.doubleValue)
        guard previous <= boundary else {
            AppLogger.error("Feedback crash watermark is ahead of the clock; prompt suppressed", category: "Diagnostics")
            return nil
        }
        let channelDisplayName = channelDisplayName
        let scan = scan
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try scan(DateInterval(start: previous, end: boundary), channelDisplayName)
        }
        let reports: [CrashReportSummary]
        do {
            reports = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let offer = try await service.claimOffer(
                from: reports,
                recoverableReportIDs: recoverableReportIDs
            )
            try Task.checkCancellation()
            // Keep the previous cursor while an offer is pending. A later
            // launch rescans the bounded interval, ledger-dedupes that offer,
            // and can claim the next unseen crash before the interval commits.
            if let offer { return offer }
            guard commitBoundary(boundary, replacing: stored) else {
                AppLogger.error("Feedback crash watermark write was not durable", category: "Diagnostics")
                return nil
            }
            return nil
        } catch {
            worker.cancel()
            AppLogger.error("Feedback crash scan did not commit its watermark", category: "Diagnostics")
            return nil
        }
    }

    /// Commits the cursor only after exact readback. A failed write or readback
    /// restores the prior value so the bounded interval is retried next launch.
    private func commitBoundary(_ boundary: Date, replacing previous: Any?) -> Bool {
        let seconds = boundary.timeIntervalSince1970
        writeBoundaryValue(NSNumber(value: seconds))
        guard (readBoundary() as? NSNumber)?.doubleValue == seconds else {
            writeBoundaryValue(previous)
            let restored = readBoundary()
            if let previous = previous as? NSNumber {
                guard (restored as? NSNumber)?.doubleValue == previous.doubleValue else {
                    AppLogger.error("Feedback crash watermark rollback was not durable", category: "Diagnostics")
                    return false
                }
            } else if restored != nil {
                AppLogger.error("Feedback crash watermark rollback was not durable", category: "Diagnostics")
                return false
            }
            return false
        }
        return true
    }
}
