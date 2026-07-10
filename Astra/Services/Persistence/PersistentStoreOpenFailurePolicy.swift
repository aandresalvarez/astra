import Foundation

/// Classifies a failed SwiftData/Core Data store open before any recovery work
/// is allowed. Unknown failures intentionally fail closed: a binary that does
/// not understand a newer schema must never reinterpret that as corruption.
public enum PersistentStoreOpenDecision: Equatable {
    case incompatibleNewerSchema
    case transientContention
    case verifiedCorruption
    case blockedUnknown
}

public enum PersistentStoreOpenFailurePolicy {
    /// Core Data reports an unknown staged model as NSCocoaErrorDomain 134504.
    /// Keep the numeric code local because Foundation exposes no stable named
    /// constant for this staged-migration-specific error.
    private static let unknownModelVersionCode = 134_504
    private static let sqliteBusyCode = 5
    private static let sqliteLockedCode = 6
    private static let sqliteCorruptCode = 11
    private static let sqliteNotADatabaseCode = 26

    public static func decision(for error: Error) -> PersistentStoreOpenDecision {
        let errors = flattenedErrors(from: error)
        let messages = errors.map { $0.localizedDescription.lowercased() } + [
            String(describing: error).lowercased(),
            String(reflecting: error).lowercased()
        ]

        if errors.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == unknownModelVersionCode }) ||
            messages.contains(where: { $0.contains("unknown model version") }) {
            return .incompatibleNewerSchema
        }

        if errors.contains(where: { isSQLiteError($0, code: sqliteBusyCode) || isSQLiteError($0, code: sqliteLockedCode) }) ||
            messages.contains(where: { $0.contains("database is locked") || $0.contains("database is busy") }) {
            return .transientContention
        }

        if errors.contains(where: { isSQLiteError($0, code: sqliteCorruptCode) || isSQLiteError($0, code: sqliteNotADatabaseCode) }) ||
            messages.contains(where: {
                $0.contains("database disk image is malformed") ||
                    $0.contains("file is not a database") ||
                    $0.contains("database corruption")
            }) {
            return .verifiedCorruption
        }

        return .blockedUnknown
    }

    /// A copied legacy store may be replaced only when SQLite has positively
    /// identified corruption. Contention, unknown failures, and schema
    /// incompatibility must preserve the migrated store and fail closed.
    public static func permitsFreshStoreForLegacyMigration(
        _ decision: PersistentStoreOpenDecision
    ) -> Bool {
        decision == .verifiedCorruption
    }

    private static func isSQLiteError(_ error: NSError, code: Int) -> Bool {
        error.domain == "NSSQLiteErrorDomain" && error.code == code
    }

    private static func flattenedErrors(from error: Error) -> [NSError] {
        var pending = [error as NSError]
        var result: [NSError] = []
        var seen = Set<String>()

        while let current = pending.popLast() {
            let key = "\(current.domain):\(current.code):\(current.localizedDescription)"
            guard seen.insert(key).inserted else { continue }
            result.append(current)
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            } else if let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error {
                pending.append(underlying as NSError)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [Error] {
                pending.append(contentsOf: detailed.map { $0 as NSError })
            }
        }
        return result
    }
}
