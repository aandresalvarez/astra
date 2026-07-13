import ASTRAModels
import ASTRAPersistence
import CoreData
import Foundation
import SwiftData
import Testing

@Suite("Orphaned V12 Store Migration")
struct OrphanedV12StoreMigratorTests {
  @MainActor
  @Test("runtime-only V12 migrates through a validated copy and preserves the source")
  func runtimeOnlyV12MigratesWithoutTouchingSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.store")
    let destinationURL = root.appendingPathComponent("recovery.store")
    let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let skillID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
    let artifactID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!

    do {
      var sourceContainer: ModelContainer? = try ModelContainer(
        for: Schema(versionedSchema: ASTRASchemaV12RuntimeOnly.self),
        configurations: [ModelConfiguration(url: sourceURL)]
      )
      let sourceContext = try #require(sourceContainer?.mainContext)

      let workspace = ASTRASchemaV12RuntimeOnly.Workspace()
      workspace.id = workspaceID
      workspace.name = "Runtime V12 Workspace"
      workspace.primaryPath = "/tmp/runtime-v12"
      sourceContext.insert(workspace)

      let skill = ASTRASchemaV12RuntimeOnly.Skill()
      skill.id = skillID
      skill.name = "Reader"
      skill.workspace = workspace
      sourceContext.insert(skill)

      let task = ASTRASchemaV12RuntimeOnly.AgentTask()
      task.id = taskID
      task.title = "Preserve me"
      task.goal = "Survive the V12 collision"
      task.runtimeID = "cursor_cli"
      task.runtimeExplicitlySelected = true
      task.workspace = workspace
      task.skills = [skill]
      sourceContext.insert(task)

      let run = ASTRASchemaV12RuntimeOnly.TaskRun()
      run.id = runID
      run.task = task
      run.output = "preserved output"
      sourceContext.insert(run)

      let event = ASTRASchemaV12RuntimeOnly.TaskEvent()
      event.id = eventID
      event.task = task
      event.run = run
      event.type = "result"
      event.payload = "preserved event"
      sourceContext.insert(event)

      let artifact = ASTRASchemaV12RuntimeOnly.Artifact()
      artifact.id = artifactID
      artifact.task = task
      artifact.type = "file"
      artifact.path = "/tmp/runtime-v12/result.md"
      sourceContext.insert(artifact)

      try sourceContext.save()
      sourceContainer = nil
    }

    let sourceBytes = try Data(contentsOf: sourceURL)
    #expect(
      PersistentStoreCompatibilityService.assess(
        storeURL: sourceURL,
        latestSupportedSchemaVersion: 13
      ) == .compatible(storeSchemaVersion: 12)
    )
    #expect(
      try PersistentStoreModelShapeService.shape(ofStoreAt: sourceURL) == .runtimeSelectionOnlyV12)
    #expect(try OrphanedV12StoreMigrator.requiresMigration(storeURL: sourceURL))
    #expect(OrphanedV12StoreMigrator.migrationProbe(storeURL: sourceURL) == .required)

    let report = try OrphanedV12StoreMigrator.migrateCopy(
      from: sourceURL,
      to: destinationURL
    )

    #expect(report.destinationStoreURL == destinationURL)
    #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    #expect(
      try PersistentStoreModelShapeService.shape(ofStoreAt: sourceURL) == .runtimeSelectionOnlyV12)

    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
      type: .sqlite, at: destinationURL)
    #expect(PersistentStoreCompatibilityService.schemaVersion(from: metadata) == 13)

    let migratedContainer = try ModelContainer(
      for: ASTRASchema.current,
      migrationPlan: ASTRAMigrationPlan.self,
      configurations: [ModelConfiguration(url: destinationURL)]
    )
    let context = migratedContainer.mainContext
    let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
    let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
    let migratedRun = try #require(try context.fetch(FetchDescriptor<TaskRun>()).first)

    #expect(migratedWorkspace.id == workspaceID)
    #expect(migratedWorkspace.tasks.map(\.id) == [taskID])
    #expect(migratedTask.runtimeID == "cursor_cli")
    #expect(migratedTask.runtimeExplicitlySelected)
    #expect(migratedTask.skills.map(\.id) == [skillID])
    #expect(migratedTask.runs.map(\.id) == [runID])
    #expect(migratedTask.events.map(\.id) == [eventID])
    #expect(migratedTask.artifacts.map(\.id) == [artifactID])
    #expect(migratedRun.output == "preserved output")
    #expect(try context.fetchCount(FetchDescriptor<FeedbackReport>()) == 0)
    let migrationRecord = try #require(
      try context.fetch(FetchDescriptor<PersistentStoreMigrationRecord>()).first
    )
    #expect(migrationRecord.sourceSchemaVersion == 12)
    #expect(migrationRecord.sourceShapeRaw == "runtime_selection_only_v12")
    #expect(migrationRecord.destinationSchemaVersion == 13)
  }

  @Test("production V12 is recognized and never routed through orphan recovery")
  func productionV12IsNotOrphaned() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("production-v12.store")
    var container: ModelContainer? = try ModelContainer(
      for: Schema(versionedSchema: ASTRASchemaV12.self),
      configurations: [ModelConfiguration(url: storeURL)]
    )
    #expect(container != nil)
    container = nil

    #expect(try PersistentStoreModelShapeService.shape(ofStoreAt: storeURL) == .productionV12)
    #expect(try !OrphanedV12StoreMigrator.requiresMigration(storeURL: storeURL))
    #expect(OrphanedV12StoreMigrator.migrationProbe(storeURL: storeURL) == .notRequired)
  }

  @Test("an unreadable store probe defers to normal open-failure recovery")
  func unreadableStoreProbeDoesNotClaimV12Migration() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("corrupt.store")
    try Data("not a sqlite store".utf8).write(to: storeURL)

    let probe = OrphanedV12StoreMigrator.migrationProbe(storeURL: storeURL)
    guard case .unavailable = probe else {
      Issue.record("Expected unreadable metadata to remain unclassified, got \(probe)")
      return
    }
    #expect(
      PersistentStoreCompatibilityService.assess(
        storeURL: storeURL,
        latestSupportedSchemaVersion: ASTRASchema.currentVersion
      ) == .unknown
    )
  }

  @MainActor
  @Test("a failed shape precondition leaves source and destination untouched")
  func unexpectedShapeFailsClosed() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.store")
    let destinationURL = root.appendingPathComponent("destination.store")
    var container: ModelContainer? = try ModelContainer(
      for: Schema(versionedSchema: ASTRASchemaV12.self),
      configurations: [ModelConfiguration(url: sourceURL)]
    )
    #expect(container != nil)
    container = nil
    let sourceBytes = try Data(contentsOf: sourceURL)

    #expect(throws: OrphanedV12StoreMigrationError.unexpectedSourceShape) {
      try OrphanedV12StoreMigrator.migrateCopy(from: sourceURL, to: destinationURL)
    }
    #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("astra-orphaned-v12-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
