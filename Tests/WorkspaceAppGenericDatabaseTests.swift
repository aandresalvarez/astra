import Foundation
import Testing
@testable import ASTRA

/// The deterministic localDatabase recipe must NOT collapse every "track X" intent to the fixed
/// grocery template — only genuine grocery intents get groceries; everything else gets a generic
/// records database named from the intent.
@Suite("Workspace App Generic Database")
struct WorkspaceAppGenericDatabaseTests {
    @Test("a non-grocery track intent classifies as localDatabase but does NOT produce groceries")
    func nonGroceryDoesNotCollapse() {
        #expect(WorkspaceAppArchetype.classify("track lab samples with a status field") == .localDatabase)
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .localDatabase, intent: "track lab samples with a status field")
        #expect(!manifest.app.name.lowercased().contains("grocery"))
        #expect(manifest.app.name.contains("Lab Samples"))
        #expect(manifest.storage?.tables.map(\.name) == ["records"])
        #expect(manifest.actions.contains { $0.type == "appStorage.insert" })
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("a genuine grocery intent still gets the rich grocery template")
    func groceryStillGrocery() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .localDatabase, intent: "store my groceries")
        #expect(manifest.app.name == "Grocery Tracker")
        #expect((manifest.storage?.tables.count ?? 0) == 3)
    }

    @Test("subjectTitle strips leading filler and titlecases the subject")
    func subjectExtraction() {
        #expect(WorkspaceAppStudioBuilder.subjectTitle(from: "track lab samples with a status field") == "Lab Samples")
        #expect(WorkspaceAppStudioBuilder.subjectTitle(from: "build me a database to store my recipes") == "Recipes")
        #expect(WorkspaceAppStudioBuilder.subjectTitle(from: "a database app") == "")
    }

    @Test("baseManifest for a non-grocery track intent is a valid non-grocery database")
    func baseManifestNonGrocery() {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "track equipment inventory by location")
        #expect(!manifest.app.name.lowercased().contains("grocery"))
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(manifest.actions.contains { $0.type == "appStorage.insert" })
    }
}
