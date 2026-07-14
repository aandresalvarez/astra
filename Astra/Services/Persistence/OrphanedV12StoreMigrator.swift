import ASTRAModels
import CoreData
import Foundation
import SQLite3
import SwiftData

public struct OrphanedV12StoreMigrationReport: Equatable, Sendable {
  public let destinationStoreURL: URL
  public let preservedRowCounts: [String: Int]
  public let sourceShapeRaw: String

  public init(
    destinationStoreURL: URL,
    preservedRowCounts: [String: Int],
    sourceShapeRaw: String
  ) {
    self.destinationStoreURL = destinationStoreURL
    self.preservedRowCounts = preservedRowCounts
    self.sourceShapeRaw = sourceShapeRaw
  }
}

public enum OrphanedV12StoreMigrationError: Error, Equatable {
  case unexpectedSourceShape
  case sourceSnapshotFailed
  case migratedStoreIntegrityFailed
  case schemaVersionMismatch(actual: Int?)
  case rowCountMismatch(table: String, expected: Int, actual: Int?)
  case feedbackTableMissingOrPopulated(actual: Int?)
  case migrationRecordMissing(actual: Int?)
}

public enum OrphanedV12StoreMigrationProbe: Equatable, Sendable {
  case required(shape: PersistentStoreKnownShape)
  case notRequired
  case unavailable(errorType: String)
}

/// Recovers either colliding historical V12 shape without touching the active
/// store. The caller supplies a new recovery URL and atomically selects it only
/// after this service returns a validated report.
public enum OrphanedV12StoreMigrator {
  private static let commonPreservedTables = [
    "ZWORKSPACE",
    "ZAGENTTASK",
    "ZTASKRUN",
    "ZTASKEVENT",
    "ZARTIFACT",
    "ZSKILL",
    "ZCONNECTOR",
    "ZLOCALTOOL",
    "ZTASKTEMPLATE",
    "ZTASKSCHEDULE",
    "ZWORKSPACEAPP",
    "ZWORKSPACEAPPRUN",
    "ZWORKSPACEAPPRUNEVENT",
    "ZWORKSPACEAPPDEPENDENCYBINDING",
    "ZWORKSPACEAPPAUTOMATIONSTATE",
    "ZGOOGLEOAUTHACCOUNTPROFILE",
    "Z_1SKILLS",
  ]

  public static func requiresMigration(storeURL: URL) throws -> Bool {
    recoverableShape(try PersistentStoreModelShapeService.shape(ofStoreAt: storeURL)) != nil
  }

  /// A read failure is intentionally distinct from a negative shape match.
  /// Startup can continue into the normal compatibility/open-failure policy,
  /// which owns corruption and transient-contention recovery decisions.
  public static func migrationProbe(storeURL: URL) -> OrphanedV12StoreMigrationProbe {
    do {
      let shape = try PersistentStoreModelShapeService.shape(ofStoreAt: storeURL)
      return recoverableShape(shape).map { .required(shape: $0) } ?? .notRequired
    } catch {
      return .unavailable(errorType: String(describing: type(of: error)))
    }
  }

  public static func migrateCopy(
    from sourceStoreURL: URL,
    to destinationStoreURL: URL,
    fileManager: FileManager = .default
  ) throws -> OrphanedV12StoreMigrationReport {
    let detectedShape = try PersistentStoreModelShapeService.shape(ofStoreAt: sourceStoreURL)
    guard let sourceShape = recoverableShape(detectedShape) else {
      throw OrphanedV12StoreMigrationError.unexpectedSourceShape
    }

    let preservedTables = preservedTables(for: sourceShape)
    let sourceCounts = try tableRowCounts(at: sourceStoreURL, tables: preservedTables)
    guard preservedTables.allSatisfy({ sourceCounts[$0] != nil }) else {
      throw OrphanedV12StoreMigrationError.sourceSnapshotFailed
    }

    var stagedCopyCreated = false
    do {
      try WorkspaceRecoveryService.copyStoreSnapshot(
        from: sourceStoreURL,
        to: destinationStoreURL
      )
      stagedCopyCreated = true
      try migrateStagedStore(at: destinationStoreURL, sourceShape: sourceShape)

      guard WorkspaceRecoveryService.sqliteIntegrityIsValid(at: destinationStoreURL) else {
        throw OrphanedV12StoreMigrationError.migratedStoreIntegrityFailed
      }

      let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
        type: .sqlite,
        at: destinationStoreURL
      )
      let version = PersistentStoreCompatibilityService.schemaVersion(from: metadata)
      guard version == ASTRASchema.currentVersion else {
        throw OrphanedV12StoreMigrationError.schemaVersionMismatch(actual: version)
      }

      let migratedCounts = try tableRowCounts(
        at: destinationStoreURL,
        tables: preservedTables + ["ZFEEDBACKREPORT", "ZPERSISTENTSTOREMIGRATIONRECORD"]
      )
      for table in preservedTables {
        let expected = sourceCounts[table] ?? 0
        guard migratedCounts[table] == expected else {
          throw OrphanedV12StoreMigrationError.rowCountMismatch(
            table: table,
            expected: expected,
            actual: migratedCounts[table]
          )
        }
      }
      if sourceShape == .runtimeSelectionOnlyV12,
         migratedCounts["ZFEEDBACKREPORT"] != 0 {
        throw OrphanedV12StoreMigrationError.feedbackTableMissingOrPopulated(
          actual: migratedCounts["ZFEEDBACKREPORT"]
        )
      }
      guard migratedCounts["ZPERSISTENTSTOREMIGRATIONRECORD"] == 1 else {
        throw OrphanedV12StoreMigrationError.migrationRecordMissing(
          actual: migratedCounts["ZPERSISTENTSTOREMIGRATIONRECORD"]
        )
      }

      return OrphanedV12StoreMigrationReport(
        destinationStoreURL: destinationStoreURL,
        preservedRowCounts: sourceCounts,
        sourceShapeRaw: sourceShapeRaw(sourceShape)
      )
    } catch {
      if stagedCopyCreated {
        removeStoreArtifacts(at: destinationStoreURL, fileManager: fileManager)
      }
      throw error
    }
  }

  private static func migrateStagedStore(
    at storeURL: URL,
    sourceShape: PersistentStoreKnownShape
  ) throws {
    let configuration = ModelConfiguration(url: storeURL)
    let container: ModelContainer
    switch sourceShape {
    case .runtimeSelectionOnlyV12:
      container = try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAOrphanedV12MigrationPlan.self,
        configurations: [configuration]
      )
    case .feedbackOnlyV12:
      container = try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAFeedbackOnlyV12MigrationPlan.self,
        configurations: [configuration]
      )
    case .productionV12, .other:
      throw OrphanedV12StoreMigrationError.unexpectedSourceShape
    }
    let context = ModelContext(container)
    context.insert(
      PersistentStoreMigrationRecord(
        sourceSchemaVersion: 12,
        sourceShapeRaw: sourceShapeRaw(sourceShape),
        destinationSchemaVersion: ASTRASchema.currentVersion,
        reason: "reconcile_colliding_v12_shapes"
      ))
    try context.save()
    withExtendedLifetime(container) {}
  }

  private static func tableRowCounts(
    at storeURL: URL,
    tables: [String]
  ) throws -> [String: Int] {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      storeURL.path,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw OrphanedV12StoreMigrationError.sourceSnapshotFailed
    }
    defer { sqlite3_close(database) }
    _ = sqlite3_busy_timeout(database, 5_000)

    return try tables.reduce(into: [:]) { counts, table in
      var statement: OpaquePointer?
      let sql = "SELECT COUNT(*) FROM \"\(table)\""
      let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
      guard prepare == SQLITE_OK, let statement else {
        if let statement { sqlite3_finalize(statement) }
        return
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw OrphanedV12StoreMigrationError.sourceSnapshotFailed
      }
      counts[table] = Int(sqlite3_column_int64(statement, 0))
    }
  }

  private static func recoverableShape(
    _ shape: PersistentStoreKnownShape
  ) -> PersistentStoreKnownShape? {
    switch shape {
    case .runtimeSelectionOnlyV12, .feedbackOnlyV12:
      return shape
    case .productionV12, .other:
      return nil
    }
  }

  private static func preservedTables(
    for shape: PersistentStoreKnownShape
  ) -> [String] {
    switch shape {
    case .feedbackOnlyV12:
      return commonPreservedTables + ["ZFEEDBACKREPORT"]
    case .runtimeSelectionOnlyV12, .productionV12, .other:
      return commonPreservedTables
    }
  }

  private static func sourceShapeRaw(_ shape: PersistentStoreKnownShape) -> String {
    switch shape {
    case .runtimeSelectionOnlyV12:
      return "runtime_selection_only_v12"
    case .feedbackOnlyV12:
      return "feedback_only_v12"
    case .productionV12:
      return "production_v12"
    case .other:
      return "other"
    }
  }

  private static func removeStoreArtifacts(at storeURL: URL, fileManager: FileManager) {
    for suffix in ["", "-shm", "-wal", ".astra-compatibility.json"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
    }
  }
}
