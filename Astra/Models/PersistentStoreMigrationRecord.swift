import Foundation
import SwiftData

/// Durable audit state for exceptional store-shape reconciliations that run
/// before the normal SwiftData container opens.
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
