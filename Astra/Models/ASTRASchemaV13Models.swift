import Foundation
import SwiftData

/// Frozen copy of the reconciliation audit entity as it existed in V13.
/// Historical schemas must never depend on the live model declaration because
/// adding a future audit field would otherwise mutate the V13 fingerprint.
public enum ASTRASchemaV13Models {
    @Model
    public final class PersistentStoreMigrationRecord {
        @Attribute(.unique) public var id: UUID
        public var sourceSchemaVersion: Int
        public var sourceShapeRaw: String
        public var destinationSchemaVersion: Int
        public var reason: String
        public var migratedAt: Date

        public init(
            id: UUID = UUID(),
            sourceSchemaVersion: Int,
            sourceShapeRaw: String,
            destinationSchemaVersion: Int,
            reason: String,
            migratedAt: Date = Date()
        ) {
            self.id = id
            self.sourceSchemaVersion = sourceSchemaVersion
            self.sourceShapeRaw = sourceShapeRaw
            self.destinationSchemaVersion = destinationSchemaVersion
            self.reason = reason
            self.migratedAt = migratedAt
        }
    }
}
