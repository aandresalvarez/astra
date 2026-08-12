import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Removes live credential values that earlier builds persisted into task
/// transcripts.
///
/// Redaction now happens where events and run output are written, but that only
/// protects text written from here on. Stores predating it hold whatever the
/// agent echoed at the time — in the incident that prompted this work, a live
/// Atlassian API token sat in three `TaskEvent` payloads, readable by anything
/// that could read the store file and by every later run that quoted the
/// transcript back. This sweep finds those values and replaces them in place.
///
/// It works from the credentials that are *currently* in the Keychain, so it
/// cannot recover a value that has since been rotated. That is the right
/// trade-off: a rotated token is no longer a credential, and inventing a
/// heuristic for "text that looks secret" would shred transcripts to chase
/// strings that no longer unlock anything.
///
/// Rows are rewritten, never deleted. A transcript with a redaction marker in
/// it still tells the user what the agent did; a missing transcript looks like
/// data loss.
@MainActor
public enum PersistedCredentialPurgeService {
    /// Rows are rewritten in bounded pages so a large store never materializes
    /// every payload at once.
    ///
    /// `nonisolated` so it can be spelled as a default argument; those are
    /// evaluated in a nonisolated context.
    nonisolated static let batchSize = 200

    public struct Outcome: Equatable {
        var secretsConsidered = 0
        var eventsRewritten = 0
        var runsRewritten = 0
        var completed = false
        /// True when no connector holds a storable credential, so the sweep
        /// returned without querying the transcript tables at all.
        var skippedNoSecrets = false
    }

    /// Build-gated so the sweep runs once per app update rather than on every
    /// launch. Re-running is harmless: a store with nothing left to find pays
    /// one count query per secret and stops.
    @discardableResult
    public static func purgeIfNeeded(
        modelContext: ModelContext,
        currentBuild: String,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard defaults.string(forKey: AppStorageKeys.completedPersistedCredentialPurgeBuild) != currentBuild else {
            return false
        }
        guard await purge(modelContext: modelContext).completed else { return false }
        defaults.set(currentBuild, forKey: AppStorageKeys.completedPersistedCredentialPurgeBuild)
        return true
    }

    @discardableResult
    static func purge(
        modelContext: ModelContext,
        store: SecretStore = SecretStoreSeam.required,
        batchSize: Int = PersistedCredentialPurgeService.batchSize
    ) async -> Outcome {
        let secrets = liveCredentialValues(modelContext: modelContext, store: store)
        guard !secrets.isEmpty else {
            return Outcome(completed: true, skippedNoSecrets: true)
        }

        var outcome = Outcome(secretsConsidered: secrets.count)
        for secret in secrets {
            // Count first. On the overwhelmingly common clean store this is the
            // only query the secret costs, and it never materializes a row.
            let eventsToFix = (try? modelContext.fetchCount(eventDescriptor(containing: secret))) ?? 0
            if eventsToFix > 0 {
                guard await rewriteEvents(
                    containing: secret,
                    secrets: secrets,
                    modelContext: modelContext,
                    batchSize: batchSize,
                    outcome: &outcome
                ) else {
                    log(stage: "event_sweep_failed", outcome: outcome)
                    return outcome
                }
            }

            let runsToFix = (try? modelContext.fetchCount(runDescriptor(containing: secret))) ?? 0
            if runsToFix > 0 {
                guard await rewriteRuns(
                    containing: secret,
                    secrets: secrets,
                    modelContext: modelContext,
                    batchSize: batchSize,
                    outcome: &outcome
                ) else {
                    log(stage: "run_sweep_failed", outcome: outcome)
                    return outcome
                }
            }
            await Task.yield()
        }

        outcome.completed = true
        if outcome.eventsRewritten > 0 || outcome.runsRewritten > 0 {
            log(stage: "purged", outcome: outcome, severity: .notable)
        }
        return outcome
    }

    /// Every credential value reachable from a connector row, in both of the
    /// Keychain namespaces a connector resolves to.
    ///
    /// Filtered by key name rather than by value shape: the same projection
    /// carries base URLs and project IDs, and replacing those with a marker
    /// would corrupt transcripts without protecting anything.
    static func liveCredentialValues(
        modelContext: ModelContext,
        store: SecretStore
    ) -> [String] {
        let connectors = (try? modelContext.fetch(FetchDescriptor<Connector>())) ?? []
        var values: [String] = []
        var seen = Set<String>()
        for connector in connectors {
            for (key, value) in connector.credentials(store: store) {
                guard RunSecretRedaction.isSecretKey(key) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= RunSecretRedaction.minimumSecretLength else { continue }
                guard seen.insert(trimmed).inserted else { continue }
                values.append(trimmed)
            }
        }
        // Longest first: a secret containing another must be replaced whole.
        return values.sorted { $0.count > $1.count }
    }

    private static func eventDescriptor(containing secret: String) -> FetchDescriptor<TaskEvent> {
        FetchDescriptor<TaskEvent>(predicate: #Predicate<TaskEvent> { $0.payload.contains(secret) })
    }

    private static func runDescriptor(containing secret: String) -> FetchDescriptor<TaskRun> {
        FetchDescriptor<TaskRun>(predicate: #Predicate<TaskRun> { $0.output.contains(secret) })
    }

    /// Pages through the matching rows, redacting each against the *whole*
    /// secret set rather than just the one that matched — a payload that leaked
    /// one credential very often leaked its neighbours in the same env dump.
    private static func rewriteEvents(
        containing secret: String,
        secrets: [String],
        modelContext: ModelContext,
        batchSize: Int,
        outcome: inout Outcome
    ) async -> Bool {
        while true {
            var descriptor = eventDescriptor(containing: secret)
            descriptor.fetchLimit = batchSize
            guard let batch = try? modelContext.fetch(descriptor) else { return false }
            guard !batch.isEmpty else { return true }
            for event in batch {
                let redacted = RunSecretRedaction.redact(event.payload, secrets: secrets)
                guard redacted != event.payload else {
                    // The predicate matched but exact replacement did not, so
                    // the loop would refetch the same row forever. Only a
                    // predicate/replacement mismatch can produce this; bail
                    // rather than spin.
                    log(stage: "event_match_not_replaceable", outcome: outcome, severity: .failure)
                    return false
                }
                event.payload = redacted
                outcome.eventsRewritten += 1
            }
            guard save(modelContext: modelContext) else { return false }
            await Task.yield()
        }
    }

    private static func rewriteRuns(
        containing secret: String,
        secrets: [String],
        modelContext: ModelContext,
        batchSize: Int,
        outcome: inout Outcome
    ) async -> Bool {
        while true {
            var descriptor = runDescriptor(containing: secret)
            descriptor.fetchLimit = batchSize
            guard let batch = try? modelContext.fetch(descriptor) else { return false }
            guard !batch.isEmpty else { return true }
            for run in batch {
                let redacted = RunSecretRedaction.redact(run.output, secrets: secrets)
                guard redacted != run.output else {
                    log(stage: "run_match_not_replaceable", outcome: outcome, severity: .failure)
                    return false
                }
                run.setOutput(redacted)
                outcome.runsRewritten += 1
            }
            guard save(modelContext: modelContext) else { return false }
            await Task.yield()
        }
    }

    private static func save(modelContext: ModelContext) -> Bool {
        do {
            // Transcript text is not a mirrored field, so the non-exporting save
            // keeps a large sweep off the workspace export path.
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                workspace: nil,
                modelContext: modelContext,
                auditFields: ["operation": "persisted_credential_purge"]
            )
            return true
        } catch {
            return false
        }
    }

    /// `LogLevel` lives in `ASTRALogging`, which this target does not depend on,
    /// so the level is chosen by an inferable member reference rather than a
    /// named parameter type.
    enum Severity {
        case notable
        case failure
    }

    /// Counts only. A log line that named the value would recreate the leak in
    /// a second place.
    private static func log(stage: String, outcome: Outcome, severity: Severity? = nil) {
        let fields = [
            "migration": "persisted_credential_purge",
            "stage": stage,
            "secrets_considered": String(outcome.secretsConsidered),
            "events_rewritten": String(outcome.eventsRewritten),
            "runs_rewritten": String(outcome.runsRewritten)
        ]
        AuditLoggingSeam.required.audit(
            .dataStoreRecovered,
            category: "Persistence",
            fields: fields,
            level: severity == nil ? .info : (severity == .failure ? .error : .warning)
        )
    }
}
