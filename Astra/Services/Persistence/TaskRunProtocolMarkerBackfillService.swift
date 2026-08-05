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
@MainActor
public enum TaskRunProtocolMarkerBackfillService {
    /// Runs are read in bounded pages so a large store never materializes every
    /// output blob at once.
    static let batchSize = 200

    /// What a single pass actually did. `completed == false` means the pass
    /// stopped early, so the caller must leave the build gate unset.
    struct Outcome: Equatable {
        var scanned = 0
        var markerBearing = 0
        var completed = false
    }

    /// Build-gated so the scan happens once per app update rather than on every
    /// launch. Re-running after an update is harmless and self-healing.
    /// `currentBuild` is supplied by the caller because `AppBuildInfo` lives in
    /// the app target, which this persistence target cannot import.
    public static func backfillIfNeeded(
        modelContext: ModelContext,
        currentBuild: String,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.string(forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild) != currentBuild else {
            return
        }
        guard backfill(modelContext: modelContext).completed else { return }
        defaults.set(currentBuild, forKey: AppStorageKeys.completedRunProtocolMarkerBackfillBuild)
    }

    @discardableResult
    static func backfill(modelContext: ModelContext) -> Outcome {
        var scanned = 0
        var markerBearing = 0

        while true {
            var descriptor = FetchDescriptor<TaskRun>(
                predicate: #Predicate<TaskRun> { $0.hasProtocolEvents == nil }
            )
            descriptor.fetchLimit = batchSize

            let batch: [TaskRun]
            do {
                batch = try modelContext.fetch(descriptor)
            } catch {
                log(stage: "fetch_failed", scanned: scanned, markerBearing: markerBearing, error: error)
                return Outcome(scanned: scanned, markerBearing: markerBearing, completed: false)
            }
            guard !batch.isEmpty else { break }

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
        }

        if scanned > 0 {
            log(stage: "completed", scanned: scanned, markerBearing: markerBearing, error: nil)
        }
        return Outcome(scanned: scanned, markerBearing: markerBearing, completed: true)
    }

    private static func log(stage: String, scanned: Int, markerBearing: Int, error: Error?) {
        var fields = [
            "migration": "run_protocol_marker_backfill",
            "stage": stage,
            "scanned": String(scanned),
            "marker_bearing": String(markerBearing)
        ]
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
