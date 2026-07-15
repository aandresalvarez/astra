import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Durable workspace canvas preferences")
struct WorkspaceCanvasItemPreferenceTests {
    private struct ExpectedSaveFailure: Error {}

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(url: url)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }
        return try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "workspace-canvas-preference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func service(in context: ModelContext) -> WorkspaceCanvasItemPreferenceService {
        WorkspaceCanvasItemPreferenceService(modelContext: context) { _, context in
            try context.save()
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Task preferences persist independently and explicit closure clears only the selected task")
    func taskPreferencesPersistIndependently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let taskA = AgentTask(title: "A", goal: "Remember Files")
        let taskB = AgentTask(title: "B", goal: "Remember Browser")
        context.insert(taskA)
        context.insert(taskB)
        try context.save()

        var persistedTaskIDs: [UUID] = []
        let preferences = WorkspaceCanvasItemPreferenceService(modelContext: context) { task, context in
            persistedTaskIDs.append(task.id)
            try context.save()
        }
        #expect(preferences.apply(.explicitUserChoice, item: .markdown, for: taskA))
        #expect(preferences.apply(.explicitUserChoice, item: .browser, for: taskB))
        #expect(preferences.rememberedItem(for: taskA) == .markdown)
        #expect(preferences.rememberedItem(for: taskB) == .browser)
        #expect(persistedTaskIDs == [taskA.id, taskB.id])

        // A task switch clears transient presentation only; no service write
        // occurs, so the prior task-owned value remains intact.
        let panel = RightPanelPresentationModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        panel.presentCanvas(.markdown)
        panel.setActiveCanvasItem(nil)
        #expect(preferences.apply(.transient, item: nil, for: taskA))
        #expect(preferences.rememberedItem(for: taskA) == .markdown)
        #expect(persistedTaskIDs == [taskA.id, taskB.id])

        #expect(preferences.apply(.explicitUserChoice, item: nil, for: taskA))
        #expect(preferences.rememberedItem(for: taskA) == nil)
        #expect(preferences.rememberedItem(for: taskB) == .browser)
        #expect(persistedTaskIDs == [taskA.id, taskB.id, taskA.id])
    }

    @Test("A fresh disk-backed container reloads the remembered item")
    func freshContainerReloadsRememberedItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-canvas-preference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.store")
        let taskID: UUID

        do {
            let container = try makeContainer(url: storeURL)
            let context = container.mainContext
            let task = AgentTask(title: "Reload", goal: "Remember Query")
            taskID = task.id
            context.insert(task)
            try context.save()
            #expect(service(in: context).setRememberedItem(.query, for: task))
        }

        let reopened = try makeContainer(url: storeURL)
        let context = reopened.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
        let task = try #require(tasks.first)
        #expect(task.rememberedWorkspaceCanvasItemRawValue == "query")
        #expect(service(in: context).rememberedItem(for: task) == .query)
    }

    @Test("Production preference writer saves directly and keeps mirror export coalesced")
    func productionPreferenceWriterUsesDirectSaveAndCoalescedMirror() throws {
        let container = try makeContainer()
        let task = AgentTask(title: "Production writer", goal: "Persist directly")
        container.mainContext.insert(task)
        try container.mainContext.save()

        let preferences = WorkspaceCanvasItemPreferenceService(modelContext: container.mainContext)
        #expect(preferences.apply(.explicitUserChoice, item: .query, for: task))

        let freshContext = ModelContext(container)
        let storedTasks = try freshContext.fetch(FetchDescriptor<AgentTask>())
        #expect(storedTasks.first?.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.query.rawValue)

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Views/WorkspaceCanvasItemPreference.swift"),
            encoding: .utf8
        )
        #expect(source.contains("saveWithoutAutoExportOrThrow"))
        #expect(source.contains("scheduleAutoExport"))
        #expect(!source.contains("saveAndAutoExportOrThrow"))
    }

    @Test("Legacy defaults key is confined to the one-time startup migration")
    func legacyDefaultsKeyIsMigrationOnly() throws {
        let sourceRoot = repoRoot.appendingPathComponent("Astra", isDirectory: true)
        let migrationPath = sourceRoot
            .appendingPathComponent("Services/Startup/LegacyWorkspaceCanvasItemPreferenceMigration.swift")
            .standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        var filesContainingLegacyKey: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("astra.workspaceCanvas.activeItemsByConversation.v1") {
                filesContainingLegacyKey.append(url.standardizedFileURL.path)
            }
        }
        #expect(filesContainingLegacyKey == [migrationPath])
    }

    @Test("Deleting a task deletes its task-owned preference without separate cleanup")
    func deletingTaskDeletesPreference() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Delete", goal: "Leave no orphan")
        let taskID = task.id
        context.insert(task)
        try context.save()
        #expect(service(in: context).setRememberedItem(.plan, for: task))

        context.delete(task)
        try context.save()

        let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        #expect(try context.fetchCount(descriptor) == 0)
        #expect(container.schema.entities.allSatisfy { $0.name != "WorkspaceCanvasItemPreference" })
    }

    @Test("A regular preference save failure rolls back only the preference field")
    func regularSaveFailureRollsBackField() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Failure", goal: "Roll back")
        context.insert(task)
        try context.save()

        let preferences = WorkspaceCanvasItemPreferenceService(modelContext: context) { _, _ in
            throw ExpectedSaveFailure()
        }
        #expect(!preferences.setRememberedItem(.browser, for: task))
        #expect(task.rememberedWorkspaceCanvasItemRawValue == nil)
    }

    @Test("Legacy migration imports supported values and ignores unsafe or stale entries")
    func legacyMigrationFiltersAndPreservesDurableValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let supportedItems: [WorkspaceCanvasItem] = [.plan, .markdown, .browser, .query, .appPreview]
        let tasks = supportedItems.map { item in
            AgentTask(title: item.rawValue, goal: "Migrate")
        }
        let existing = AgentTask(title: "Existing", goal: "Do not overwrite")
        existing.rememberedWorkspaceCanvasItemRawValue = WorkspaceCanvasItem.plan.rawValue
        let unsupported = AgentTask(title: "Unsupported", goal: "Ignore unknown value")
        for task in tasks + [existing, unsupported] {
            context.insert(task)
        }
        try context.save()

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let orphanID = UUID()
        var entries = Dictionary(uniqueKeysWithValues: zip(tasks, supportedItems).map { task, item in
            (task.id.uuidString, item.rawValue)
        })
        entries[existing.id.uuidString] = WorkspaceCanvasItem.browser.rawValue
        entries[unsupported.id.uuidString] = "futureShelf"
        entries[orphanID.uuidString] = WorkspaceCanvasItem.markdown.rawValue
        entries["not-a-uuid"] = WorkspaceCanvasItem.plan.rawValue
        defaults.set(String(decoding: try JSONEncoder().encode(entries), as: UTF8.self),
                     forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey)

        var sourcePresentDuringSave = false
        let result = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context,
            persist: { _, context in
                sourcePresentDuringSave = defaults.object(
                    forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey
                ) != nil
                try context.save()
            }
        )

        #expect(sourcePresentDuringSave)
        #expect(result.migratedCount == supportedItems.count)
        #expect(result.existingDurableCount == 1)
        #expect(result.orphanCount == 1)
        #expect(result.malformedIDCount == 1)
        #expect(result.unsupportedValueCount == 1)
        #expect(result.sourceRemoved)
        #expect(defaults.object(forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey) == nil)
        for (task, item) in zip(tasks, supportedItems) {
            #expect(task.rememberedWorkspaceCanvasItemRawValue == item.rawValue)
        }
        #expect(existing.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.plan.rawValue)
        #expect(unsupported.rememberedWorkspaceCanvasItemRawValue == nil)

        let second = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context,
            persist: { _, _ in Issue.record("idempotent migration unexpectedly saved") }
        )
        #expect(!second.sourceFound)
    }

    @Test("Legacy migration tolerates malformed siblings and deterministically handles duplicate IDs")
    func legacyMigrationHandlesDuplicateIDsAndMixedValueTypes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sharedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let preferred = AgentTask(title: "Earlier", goal: "Deterministic winner")
        preferred.id = sharedID
        preferred.createdAt = Date(timeIntervalSince1970: 1)
        let duplicate = AgentTask(title: "Later", goal: "Ignored duplicate row")
        duplicate.id = sharedID
        duplicate.createdAt = Date(timeIntervalSince1970: 2)
        let validSibling = AgentTask(title: "Valid sibling", goal: "Survives malformed sibling")
        let malformedSibling = AgentTask(title: "Malformed sibling", goal: "Ignored value")
        for task in [preferred, duplicate, validSibling, malformedSibling] {
            context.insert(task)
        }
        try context.save()

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entries: [String: Any] = [
            sharedID.uuidString: WorkspaceCanvasItem.browser.rawValue,
            sharedID.uuidString.lowercased(): WorkspaceCanvasItem.query.rawValue,
            validSibling.id.uuidString: WorkspaceCanvasItem.markdown.rawValue,
            malformedSibling.id.uuidString: 42
        ]
        let source = String(
            decoding: try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]),
            as: UTF8.self
        )
        defaults.set(source, forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey)

        let result = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context,
            persist: { _, context in try context.save() }
        )

        #expect(result.migratedCount == 2)
        #expect(result.duplicateTaskCount == 2)
        #expect(result.unsupportedValueCount == 1)
        #expect(preferred.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.browser.rawValue)
        #expect(duplicate.rememberedWorkspaceCanvasItemRawValue == nil)
        #expect(validSibling.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.markdown.rawValue)
        #expect(malformedSibling.rememberedWorkspaceCanvasItemRawValue == nil)
        #expect(result.sourceRemoved)
    }

    @Test("Failed legacy persistence retains the exact source and restores touched tasks for retry")
    func failedLegacyPersistenceRetainsSource() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Retry", goal: "Keep source")
        context.insert(task)
        try context.save()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = String(decoding: try JSONEncoder().encode([
            task.id.uuidString: WorkspaceCanvasItem.markdown.rawValue
        ]), as: UTF8.self)
        defaults.set(source, forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey)

        let failed = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context,
            persist: { _, _ in throw ExpectedSaveFailure() }
        )
        #expect(failed.failed)
        #expect(!failed.sourceRemoved)
        #expect(task.rememberedWorkspaceCanvasItemRawValue == nil)
        #expect(defaults.string(forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey) == source)

        let retried = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context,
            persist: { _, context in try context.save() }
        )
        #expect(!retried.failed)
        #expect(retried.migratedCount == 1)
        #expect(retried.sourceRemoved)
        #expect(task.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.markdown.rawValue)
    }

    @Test("Production migration entry persists through an isolated context before a fresh read")
    func productionMigrationUsesIsolatedContext() throws {
        let container = try makeContainer()
        let task = AgentTask(title: "Startup", goal: "Migrate before restore")
        container.mainContext.insert(task)
        try container.mainContext.save()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = String(decoding: try JSONEncoder().encode([
            task.id.uuidString: WorkspaceCanvasItem.appPreview.rawValue
        ]), as: UTF8.self)
        defaults.set(source, forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey)

        let result = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContainer: container
        )

        let freshContext = ModelContext(container)
        let migratedTasks = try freshContext.fetch(FetchDescriptor<AgentTask>())
        #expect(result.migratedCount == 1)
        #expect(result.sourceRemoved)
        #expect(migratedTasks.first?.rememberedWorkspaceCanvasItemRawValue == WorkspaceCanvasItem.appPreview.rawValue)
    }

    @Test("Malformed legacy JSON is discarded safely without touching task state")
    func malformedLegacyJSONIsDiscardedSafely() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Malformed", goal: "Remain unchanged")
        context.insert(task)
        try context.save()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("[not-a-map]", forKey: LegacyWorkspaceCanvasItemPreferenceMigration.legacyDefaultsKey)

        let result = LegacyWorkspaceCanvasItemPreferenceMigration.migrate(
            defaults: defaults,
            modelContext: context
        )
        #expect(result.sourceRemoved)
        #expect(task.rememberedWorkspaceCanvasItemRawValue == nil)
    }
}
