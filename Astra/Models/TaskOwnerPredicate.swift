import Foundation
import SwiftData
import os

/// Predicates that reach one task's rows through the relationship's index,
/// for the systems where SwiftData can run them.
///
/// The form every supported system accepts is the optional chain:
/// `$0.task?.id == taskID` or `$0.task?.persistentModelID == owner`. SwiftData
/// turns it into `CASE (ZTASK IS NOT NULL) WHEN 1 THEN … END = ?`, which no
/// index can serve. The read walks the whole table however few rows the task
/// has, so it slows down as every *other* task grows: 40 to 70 ms per read on
/// a store with 185,000 events, several times per context refresh.
///
/// A checked forced unwrap, `$0.task != nil && $0.task!.persistentModelID ==
/// owner`, becomes `ZTASK IS NOT NULL AND ZTASK = ?` and uses the index (3 ms
/// on the same store). SwiftData translates it from macOS 27. Before that the
/// same predicate throws `unsupportedPredicate` when it is fetched, and a
/// reader with a `try?` fallback then quietly returns something else.
///
/// So the hot reads keep the portable predicate they always had and hand both
/// to `pick`, which returns the indexed one only where a fetch with it has
/// actually worked. Every predicate with a forced unwrap lives in this file.
///
/// The `!= nil` is not decoration. SwiftData also evaluates a predicate in
/// memory against unsaved rows, and there a bare `$0.task!` on a row without
/// a task throws; `&&` stops before the unwrap.
public enum TaskOwnerPredicate {
    // MARK: - Choosing

    /// `indexed` where SwiftData can run it, otherwise `portable`. The two
    /// must select the same rows of `owner`; `portable` may also match rows of
    /// another task that shares the owner's UUID, which callers already
    /// filter out by persistent identity.
    public static func pick<Model: PersistentModel>(
        for owner: PersistentIdentifier,
        in context: ModelContext,
        indexed: Predicate<Model>,
        portable: Predicate<Model>
    ) -> Predicate<Model> {
        usesRelationshipIndex(for: owner, in: context) ? indexed : portable
    }

    /// Whether SwiftData runs the checked forced unwrap on this system.
    ///
    /// Never before macOS 27, where it is known to throw. From macOS 27 the
    /// first call proves it with one indexed fetch instead of trusting the
    /// version alone, and the answer is kept for the life of the process: it
    /// is a property of the framework, not of the store or the task.
    public static func usesRelationshipIndex(for owner: PersistentIdentifier, in context: ModelContext) -> Bool {
        guard #available(macOS 27, *) else { return false }
        #if DEBUG
        if forcedPortable { return false }
        #endif
        if let known = verdict.withLock({ $0 }) { return known }
        var probe = FetchDescriptor<TaskEvent>(predicate: events(ownedBy: owner))
        probe.fetchLimit = 1
        do {
            _ = try context.fetch(probe)
            verdict.withLock { $0 = true }
            return true
        } catch is SwiftDataError {
            verdict.withLock { $0 = false }
            return false
        } catch {
            // Not an answer about the predicate; ask again next time.
            return false
        }
    }

    private static let verdict = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    #if DEBUG
    /// `ASTRA_PORTABLE_TASK_PREDICATES=1` makes a debug build on macOS 27 take
    /// the portable predicates, so a local test run can cover the path that
    /// older systems, and CI while it runs one, take.
    private static let forcedPortable =
        ProcessInfo.processInfo.environment["ASTRA_PORTABLE_TASK_PREDICATES"] == "1"
    #endif

    // MARK: - Events

    public static func events(ownedBy owner: PersistentIdentifier) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner }
    }

    public static func events(ownedBy owner: PersistentIdentifier, type: String) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.type == type }
    }

    public static func events(ownedBy owner: PersistentIdentifier, type: String, runID: UUID) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> {
            $0.task != nil && $0.task!.persistentModelID == owner && $0.type == type && $0.run?.id == runID
        }
    }

    public static func events(ownedBy owner: PersistentIdentifier, types: [String]) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && types.contains($0.type) }
    }

    public static func events(ownedBy owner: PersistentIdentifier, typePrefix prefix: String) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.type.starts(with: prefix) }
    }

    public static func events(
        ownedBy owner: PersistentIdentifier,
        types: [String],
        orTypePrefix prefix: String
    ) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> {
            $0.task != nil && $0.task!.persistentModelID == owner
                && (types.contains($0.type) || $0.type.starts(with: prefix))
        }
    }

    /// Events of `types`, plus those of `prefixedType` whose payload starts
    /// with `payloadPrefix`.
    public static func events(
        ownedBy owner: PersistentIdentifier,
        types: [String],
        orType prefixedType: String,
        withPayloadPrefix payloadPrefix: String
    ) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> {
            $0.task != nil && $0.task!.persistentModelID == owner
                && (types.contains($0.type) || ($0.type == prefixedType && $0.payload.starts(with: payloadPrefix)))
        }
    }

    public static func events(
        ownedBy owner: PersistentIdentifier,
        excludingTypes first: String,
        _ second: String,
        _ third: String
    ) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> {
            $0.task != nil && $0.task!.persistentModelID == owner
                && $0.type != first && $0.type != second && $0.type != third
        }
    }

    public static func events(ownedBy owner: PersistentIdentifier, payload: String) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.payload == payload }
    }

    public static func events(ownedBy owner: PersistentIdentifier, runID: UUID) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.run?.id == runID }
    }

    public static func events(ownedBy owner: PersistentIdentifier, id: UUID) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.id == id }
    }

    public static func events(ownedBy owner: PersistentIdentifier, ids: [UUID]) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && ids.contains($0.id) }
    }

    public static func events(ownedBy owner: PersistentIdentifier, since date: Date) -> Predicate<TaskEvent> {
        #Predicate<TaskEvent> { $0.task != nil && $0.task!.persistentModelID == owner && $0.timestamp >= date }
    }

    // MARK: - Artifacts

    public static func artifacts(ownedBy owner: PersistentIdentifier) -> Predicate<Artifact> {
        #Predicate<Artifact> { $0.task != nil && $0.task!.persistentModelID == owner }
    }
}
