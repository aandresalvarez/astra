import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Resolves the tri-state `TaskRun.hasProtocolEvents` for rows written before
/// schema V17.
///
/// Plan recovery selects candidate runs with `hasProtocolEvents != false`, so a
/// never-scanned (`nil`) row is always returned and its output blob is scanned
/// in memory - correct, but exactly the cost the flag exists to avoid. This
/// one-time pass reads each legacy blob once and pins the flag to true/false,
/// after which the predicate can reject clean runs in SQLite.
///
/// Purely a performance step: failing leaves the flag unset so the pass retries
/// on the next launch, and readers stay correct in the meantime.
///
/// The pass is `async` and suspends between batches on purpose. Materializing
/// and scanning an `output` blob is main-actor work, so a store with tens of
/// thousands of legacy runs would otherwise hold the main actor for the whole
/// sweep on the first launch after an update - the exact stall the flag exists
/// to remove, moved onto the launch path. Batching alone only bounds *memory*;
/// the `Task.yield()` between batches is what bounds the hitch.
@MainActor
public enum TaskRunProtocolMarkerBackfillService {
    /// Runs are read in bounded pages so a large store never materializes every
    /// output blob at once, and so a single uninterrupted main-actor stretch is
    /// capped at one page of blob scans.
    ///
    /// `nonisolated` so it can be spelled as `backfill`'s default argument;
    /// default-argument expressions are evaluated in a nonisolated context.
    nonisolated static let batchSize = 200

    /// Mirrors `PerformanceTelemetry.backgroundThresholdMilliseconds`. That type
    /// lives in the app target, which this persistence target cannot import, so
    /// the duration is reported through this service's own audit record.
    static let batchTelemetryThresholdMilliseconds: Double = 20

    /// What a single pass actually did. `completed == false` means the pass
    /// stopped early, so the caller must leave the build gate unset.
    struct Outcome: Equatable {
        var scanned = 0
        var markerBearing = 0
        var completed = false
        /// True when the cheap pending-count probe found nothing to resolve, so
        /// the pass returned without materializing a single row. Fresh installs
        /// and stores already resolved by an earlier build take this path.
        var skippedEmptyStore = false
    }

    /// Build-gated so the scan happens once per app update rather than on every
    /// launch. Re-running after an update is harmless and self-healing.
    /// `currentBuild` is supplied by the caller because `AppBuildInfo` lives in
    /// the app target, which this persistence target cannot import.
    @discardableResult
    public static func backfillIfNeeded(
        modelContext: ModelContext,
        currentBuild: String,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard defaults.string(forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild) != currentBuild else {
            return false
        }
        guard await backfill(modelContext: modelContext).completed else { return false }
        defaults.set(currentBuild, forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild)
        return true
    }

    @discardableResult
    static func backfill(
        modelContext: ModelContext,
        batchSize: Int = TaskRunProtocolMarkerBackfillService.batchSize
    ) async -> Outcome {
        // Cheap aggregate first. A fresh install has no `nil` rows at all, so it
        // pays one COUNT instead of a fetch that materializes managed objects.
        let pendingDescriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.hasProtocolEvents == nil }
        )
        do {
            guard try modelContext.fetchCount(pendingDescriptor) > 0 else {
                return Outcome(completed: true, skippedEmptyStore: true)
            }
        } catch {
            log(stage: "count_failed", scanned: 0, markerBearing: 0, error: error)
            return Outcome(completed: false)
        }

        var scanned = 0
        var markerBearing = 0
        var batches = 0

        while true {
            var descriptor = pendingDescriptor
            descriptor.fetchLimit = batchSize

            let batch: [TaskRun]
            do {
                batch = try modelContext.fetch(descriptor)
            } catch {
                log(stage: "fetch_failed", scanned: scanned, markerBearing: markerBearing, error: error)
                return Outcome(scanned: scanned, markerBearing: markerBearing, completed: false)
            }
            guard !batch.isEmpty else { break }

            let batchStart = DispatchTime.now().uptimeNanoseconds
            for run in batch {
                run.refreshProtocolMarkerFlag()
                scanned += 1
                if run.hasProtocolEvents == true { markerBearing += 1 }
            }

            do {
                // Runs mirror into their workspace JSON, but this pass writes no
                // mirrored field - the flag is store-only derived state - so the
                // non-exporting save keeps a large backfill off the export path.
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                    workspace: nil,
                    modelContext: modelContext,
                    auditFields: ["operation": "run_protocol_marker_backfill"]
                )
            } catch {
                log(stage: "save_failed", scanned: scanned, markerBearing: markerBearing, error: error)
                return Outcome(scanned: scanned, markerBearing: markerBearing, completed: false)
            }

            batches += 1
            logBatchIfSlow(
                startNanoseconds: batchStart,
                batchCount: batch.count,
                scanned: scanned,
                markerBearing: markerBearing
            )

            // The only line standing between a large legacy store and a frozen
            // first launch. Do not remove it to "tighten the loop".
            await Task.yield()
        }

        if scanned > 0 {
            log(
                stage: "completed",
                scanned: scanned,
                markerBearing: markerBearing,
                error: nil,
                extraFields: ["batches": String(batches)]
            )
        }
        return Outcome(scanned: scanned, markerBearing: markerBearing, completed: true)
    }

    /// Per-batch duration, reported only when a batch exceeds the background
    /// work threshold, so a pathological store is visible in the logs instead of
    /// showing up only as a user-reported hang.
    private static func logBatchIfSlow(
        startNanoseconds: UInt64,
        batchCount: Int,
        scanned: Int,
        markerBearing: Int
    ) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000
        guard elapsed >= batchTelemetryThresholdMilliseconds else { return }
        log(
            stage: "batch_slow",
            scanned: scanned,
            markerBearing: markerBearing,
            error: nil,
            extraFields: [
                "batch_count": String(batchCount),
                "duration_ms": String(format: "%.2f", elapsed)
            ]
        )
    }

    private static func log(
        stage: String,
        scanned: Int,
        markerBearing: Int,
        error: Error?,
        extraFields: [String: String] = [:]
    ) {
        var fields = [
            "migration": "run_protocol_marker_backfill",
            "stage": stage,
            "scanned": String(scanned),
            "marker_bearing": String(markerBearing)
        ]
        fields.merge(extraFields) { _, new in new }
        if let error {
            fields["error_type"] = String(describing: type(of: error))
        }
        AuditLoggingSeam.required.audit(
            .dataStoreRecovered,
            category: "Persistence",
            fields: fields,
            level: error == nil ? .info : .error
        )
    }
}
