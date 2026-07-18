import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace Package Import")
struct WorkspacePackageImportTests {

    // MARK: - Round trip

    @MainActor
    @Test("package import round trips into a clean container with a fresh workspace identity")
    func importRoundTripsIntoCleanContainer() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let targetLibrary = CapabilityLibrary(directory: root.appendingPathComponent("target-capabilities", isDirectory: true))
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = targetLibrary
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        // Fresh identity: a portable share behaves like "duplicate", never
        // "replace" — two recipients must not collide.
        #expect(outcome.workspace.id != fixture.sourceWorkspaceID)
        // Destination anchoring: the workspace root is the chosen folder,
        // never wherever the package happened to sit.
        let expectedRoot = destinationParent.appendingPathComponent("Package Export", isDirectory: true)
        #expect(outcome.workspace.primaryPath == expectedRoot.path)
        #expect(FileManager.default.fileExists(atPath: expectedRoot.path))

        #expect(outcome.skillCount == 0)
        #expect(outcome.connectorCount == 1)
        #expect(outcome.connectorsNeedingCredentials == ["Tracker"])

        // Enabled schedules import disabled.
        #expect(outcome.quarantinedScheduleCount == 1)
        let importedSchedules = outcome.workspace.schedules
        #expect(importedSchedules.count == 1)
        #expect(importedSchedules.allSatisfy { !$0.isEnabled })

        // The app landed with a loadable manifest at the new root.
        #expect(outcome.appsImported == ["Notes"])
        let importedApps = try Self.apps(in: targetContainer.mainContext, workspaceID: outcome.workspace.id)
        #expect(importedApps.count == 1)
        let loaded = try WorkspaceAppManifestStore().loadManifest(
            app: try #require(importedApps.first),
            workspace: outcome.workspace
        )
        #expect(loaded.manifest.app.name == "Notes")

        // The custom capability landed in the target library as a draft.
        #expect(outcome.capabilitiesInstalledAsDraft == ["local.tool"])
        let installed = try #require(targetLibrary.installedPackage(id: "local.tool"))
        #expect(installed.governance.approvalStatus == .draft)
        // ...and is NOT auto-enabled: an embedded draft must stay off the
        // imported workspace's enabled set until the recipient approves it,
        // or the runtime resource matcher would expose it to task runs while
        // the review UI still says "pending approval". (A custom capability
        // always reads back as draft from the library — its ID isn't a trusted
        // built-in — so the enabled-set strip is unconditional in practice; the
        // approved-stays-enabled branch is reachable only for genuine built-ins,
        // which a fixture can't fake without coupling to the real catalog.)
        #expect(outcome.workspace.enabledCapabilityIDs.isEmpty)
    }

    @MainActor
    @Test("embedded draft capabilities stay enabled while apps import, then are disabled")
    func draftCapabilitiesEnabledDuringAppImportThenDisabled() throws {
        // Regression for the tension between "don't expose an unapproved draft to
        // task runs" (strip it from the enabled set) and "map the app's
        // dependency bindings" (createApp derives bindings from the workspace's
        // CURRENTLY enabled capabilities). The strip must therefore happen AFTER
        // the apps import, not before — otherwise the binding persists unmapped
        // and never recovers even after the recipient approves the capability.
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let targetLibrary = CapabilityLibrary(directory: root.appendingPathComponent("target-capabilities", isDirectory: true))
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var enabledDuringAppImport: [String]?
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = targetLibrary
        coordinator.importAppBundle = { bundleURL, workspace, modelContext in
            // The moment an app is imported, the embedded draft must still be in
            // the workspace's enabled set so its dependency bindings can map.
            enabledDuringAppImport = workspace.enabledCapabilityIDs
            return try WorkspaceAppPackageService().importPackage(
                at: bundleURL,
                into: workspace,
                modelContext: modelContext,
                persistence: .deferSave
            )
        }
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        #expect(enabledDuringAppImport?.contains("local.tool") == true)
        // Committed state: the draft is no longer runtime-exposed, matching the
        // "pending approval" the review UI shows.
        #expect(!outcome.workspace.enabledCapabilityIDs.contains("local.tool"))
        #expect(outcome.capabilitiesInstalledAsDraft == ["local.tool"])
    }

    @MainActor
    @Test("export omits machine-local paths so the package never carries them")
    func exportOmitsMachineLocalPaths() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extraPath = root.appendingPathComponent("elsewhere", isDirectory: true).path
        let fixture = try Self.exportedPackage(root: root) { workspace in
            workspace.additionalPaths = [extraPath]
        }

        // The sender's absolute paths never entered the package — a recipient
        // reading workspace-config.json cannot see where the sender's files live.
        let configText = String(
            decoding: try Data(contentsOf: fixture.packageURL.appendingPathComponent("workspace-config.json")),
            as: UTF8.self
        )
        #expect(!configText.contains(extraPath))

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        // Nothing to drop on import because nothing traveled; the checklist does
        // not re-expose sender paths either.
        #expect(outcome.droppedMachinePaths.isEmpty)
        #expect(outcome.workspace.additionalPaths.isEmpty)
        #expect(outcome.workspace.activeWorkingPath == nil)
    }

    @MainActor
    @Test("a failed import does not roll back the caller context's unrelated pending edits")
    func failedImportPreservesUnrelatedPendingEdits() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let callerContainer = try Self.makeContainer()
        let callerContext = callerContainer.mainContext

        // An unrelated workspace already open in the UI: saved baseline, then a
        // pending (unsaved) edit the user is in the middle of making.
        let other = Workspace(
            name: "Original",
            primaryPath: root.appendingPathComponent("other", isDirectory: true).path
        )
        callerContext.insert(other)
        try callerContext.save()
        other.name = "Pending edit"

        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )
        struct ImportBoom: Error {}
        coordinator.importAppBundle = { _, _, _ in throw ImportBoom() }

        #expect(throws: (any Error).self) {
            _ = try coordinator.importPackage(
                at: fixture.packageURL,
                intoDestinationFolder: destinationParent,
                modelContext: callerContext
            )
        }

        // The import rolled back only its own dedicated context — the caller's
        // unrelated pending edit is untouched (a shared-context rollback would
        // have reverted it to "Original").
        #expect(other.name == "Pending edit")
        // ...and nothing from the failed import leaked into the caller context.
        let leaked = try callerContext.fetch(
            FetchDescriptor<Workspace>(predicate: #Predicate { $0.name == "Package Export" })
        )
        #expect(leaked.isEmpty)
    }

    @MainActor
    @Test("import refuses a package whose bytes changed after the reviewed fingerprint")
    func importRefusesPackageChangedSinceReview() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )

        // A fingerprint that does not match the package now at the URL (as if a
        // different package were swapped in after review).
        let staleDigest = String(repeating: "0", count: 64)
        #expect(throws: WorkspacePackageImportError.self) {
            _ = try coordinator.importPackage(
                at: fixture.packageURL,
                intoDestinationFolder: destinationParent,
                modelContext: targetContainer.mainContext,
                expectedPackageDigest: staleDigest
            )
        }
        #expect(try targetContainer.mainContext.fetch(FetchDescriptor<Workspace>()).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: destinationParent.appendingPathComponent("Package Export").path
        ))

        // The genuine fingerprint of the reviewed bytes imports normally.
        let realDigest = try #require(WorkspacePackageImportCoordinator.packageFingerprint(at: fixture.packageURL))
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext,
            expectedPackageDigest: realDigest
        )
        #expect(outcome.appsImported == ["Notes"])
    }

    @MainActor
    @Test("package import skips already-installed capabilities without overwriting them")
    func importSkipsAlreadyInstalledCapabilities() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let targetLibrary = CapabilityLibrary(directory: root.appendingPathComponent("target-capabilities", isDirectory: true))
        var existing = Self.makeCapability(id: "local.tool", governance: .localDraft())
        existing.name = "Pre-existing Capability"
        try targetLibrary.install(existing, sourceMetadata: .localLibrary())

        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = targetLibrary
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        #expect(outcome.capabilitiesInstalledAsDraft.isEmpty)
        #expect(outcome.capabilitiesAlreadyInstalled == ["local.tool"])
        // The pre-existing library entry was not clobbered by the package's copy.
        #expect(targetLibrary.installedPackage(id: "local.tool")?.name == "Pre-existing Capability")
    }

    @MainActor
    @Test("import does not activate a recipient-local unapproved capability the package merely names")
    func importDoesNotActivateRecipientLocalUnapprovedCapability() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The share enables an ID it does NOT embed — one that happens to exist,
        // unapproved, in the recipient's own library. Plus its own embedded draft.
        let fixture = try Self.exportedPackage(root: root) { workspace in
            workspace.enabledCapabilityIDs = ["local.tool", "recipient.private"]
        }

        let targetContainer = try Self.makeContainer()
        let targetLibrary = CapabilityLibrary(directory: root.appendingPathComponent("target-capabilities", isDirectory: true))
        try targetLibrary.install(
            Self.makeCapability(id: "recipient.private", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = targetLibrary
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        // Neither the package's own just-installed draft nor the recipient's
        // pre-existing unapproved capability is left enabled by an untrusted share.
        #expect(!outcome.workspace.enabledCapabilityIDs.contains("local.tool"))
        #expect(!outcome.workspace.enabledCapabilityIDs.contains("recipient.private"))
        // The recipient's own capability is untouched, just not auto-enabled.
        #expect(targetLibrary.installedPackage(id: "recipient.private")?.governance.approvalStatus == .draft)
    }

    @MainActor
    @Test("import does not enable recipient global resources named by the share")
    func importDoesNotEnableRecipientGlobalResources() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root) { workspace in
            workspace.enabledGlobalConnectorIDs = ["recipient-global-connector"]
            workspace.enabledGlobalSkillIDs = ["recipient-global-skill"]
            workspace.enabledGlobalToolIDs = ["recipient-global-tool"]
        }

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )
        let outcome = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        // A shared workspace never reaches into the recipient's global catalog.
        #expect(outcome.workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(outcome.workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(outcome.workspace.enabledGlobalToolIDs.isEmpty)
    }

    @MainActor
    @Test("import consumes a private copy and leaves no staging residue")
    func importConsumesPrivateCopyAndCleansUp() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )

        _ = try coordinator.importPackage(
            at: fixture.packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        // The staged private copy is removed once the import completes.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("astra-share-import-") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Rollback

    @MainActor
    @Test("failed app import rolls back workspace rows, files, and installed capabilities")
    func failedImportRollsBackEverything() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let targetContainer = try Self.makeContainer()
        let targetLibrary = CapabilityLibrary(directory: root.appendingPathComponent("target-capabilities", isDirectory: true))
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        struct InjectedFailure: Error {}
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = targetLibrary
        coordinator.importAppBundle = { _, _, _ in throw InjectedFailure() }

        #expect(throws: InjectedFailure.self) {
            _ = try coordinator.importPackage(
                at: fixture.packageURL,
                intoDestinationFolder: destinationParent,
                modelContext: targetContainer.mainContext
            )
        }

        // No partial workspace: rows rolled back, destination folder removed,
        // nothing orphaned in the capability library.
        let workspaces = try targetContainer.mainContext.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.isEmpty)
        let destinationContents = try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
        #expect(destinationContents.isEmpty)
        #expect(targetLibrary.installedPackage(id: "local.tool") == nil)
    }

    @MainActor
    @Test("import rejects a tampered package before creating anything")
    func importRejectsTamperedPackageBeforeMutation() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root)

        let configURL = fixture.packageURL.appendingPathComponent("workspace-config.json")
        var data = try Data(contentsOf: configURL)
        data.append(contentsOf: "\n// tampered".utf8)
        try data.write(to: configURL)

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("target-capabilities", isDirectory: true)
        )
        #expect(throws: WorkspacePackageImportError.self) {
            _ = try coordinator.importPackage(
                at: fixture.packageURL,
                intoDestinationFolder: destinationParent,
                modelContext: targetContainer.mainContext
            )
        }

        let destinationContents = try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
        #expect(destinationContents.isEmpty)
        let workspaces = try targetContainer.mainContext.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.isEmpty)
    }

    // MARK: - Plan classification

    @MainActor
    @Test("import plan classifies apps, capabilities, connectors, accounts, and schedules")
    func planClassifiesReadiness() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Self.exportedPackage(root: root) { workspace in
            // One capability the recipient has, one it doesn't.
            workspace.enabledCapabilityIDs = ["local.tool", "missing.builtin"]
        }

        let report = WorkspacePackageService().validatePackage(at: fixture.packageURL)
        #expect(report.canInstall)

        var planner = WorkspacePackageImportPlanner()
        planner.installedCapabilityIDs = { [] }
        let plan = try #require(planner.plan(from: report))

        #expect(plan.canImport)
        #expect(plan.workspaceName == "Package Export")
        #expect(plan.quarantinedScheduleCount == 1)

        let appItem = try #require(plan.apps.first)
        #expect(appItem.status == .ready)

        let embeddedItem = try #require(plan.capabilities.first { $0.id == "capability:local.tool" })
        #expect(embeddedItem.status == .needsApproval)
        let missingItem = try #require(plan.capabilities.first { $0.id == "capability:missing.builtin" })
        #expect(missingItem.status == .missing)

        let connectorItem = try #require(plan.connectors.first)
        #expect(connectorItem.status == .needsAuthentication)
        #expect(connectorItem.detail.contains("API_TOKEN"))

        // Same package on a machine that already has the capability.
        var installedPlanner = WorkspacePackageImportPlanner()
        installedPlanner.installedCapabilityIDs = { ["local.tool", "missing.builtin"] }
        let installedPlan = try #require(installedPlanner.plan(from: report))
        let alreadyItem = try #require(installedPlan.capabilities.first { $0.id == "capability:local.tool" })
        #expect(alreadyItem.status == .alreadyInstalled)
        let readyItem = try #require(installedPlan.capabilities.first { $0.id == "capability:missing.builtin" })
        #expect(readyItem.status == .ready)
    }

    // MARK: - Fixtures

    struct ExportedPackageFixture {
        var packageURL: URL
        var sourceWorkspaceID: UUID
    }

    /// Builds a source workspace with one connector requiring credentials,
    /// one enabled schedule, one workspace app, and one custom capability,
    /// then exports it as a `.astra-share` package.
    @MainActor
    private static func exportedPackage(
        root: URL,
        configure: (Workspace) -> Void = { _ in }
    ) throws -> ExportedPackageFixture {
        let container = try makeContainer()
        let workspaceURL = root.appendingPathComponent("source-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Export", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let connector = Connector(
            name: "Tracker",
            serviceType: "tracker",
            connectorDescription: "Issue tracker.",
            baseURL: "https://tracker.example.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["API_TOKEN"]
        connector.workspace = workspace
        container.mainContext.insert(connector)

        let schedule = TaskSchedule(name: "Nightly triage", goal: "Summarize new issues", workspace: workspace)
        schedule.isEnabled = true
        container.mainContext.insert(schedule)

        let sourceAppPackageURL = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: minimalAppManifest(id: "notes", name: "Notes"),
            to: sourceAppPackageURL
        )
        _ = try WorkspaceAppPackageService().importPackage(
            at: sourceAppPackageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let sourceLibrary = CapabilityLibrary(directory: root.appendingPathComponent("source-capabilities", isDirectory: true))
        try sourceLibrary.install(
            makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        configure(workspace)

        let packageURL = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: sourceLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: packageURL
        )
        return ExportedPackageFixture(packageURL: packageURL, sourceWorkspaceID: workspace.id)
    }

    @MainActor
    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @MainActor
    private static func apps(in modelContext: ModelContext, workspaceID: UUID) throws -> [WorkspaceApp] {
        try modelContext.fetch(
            FetchDescriptor<WorkspaceApp>(predicate: #Predicate { $0.workspaceID == workspaceID })
        )
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-package-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func minimalAppManifest(id: String, name: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(app: WorkspaceAppManifestMetadata(
            id: id,
            name: name,
            icon: "app",
            description: "Fixture app.",
            tags: [],
            archetypes: []
        ))
    }

    private static func makeCapability(id: String, governance: CapabilityGovernance) -> PluginPackage {
        PluginPackage(
            id: id,
            name: "Fixture Capability",
            icon: "puzzlepiece.extension",
            description: "Fixture capability for package import tests.",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: governance
        )
    }
}

// MARK: - Review sheet state

/// Regression tests for the review sheet's state handling (live-QA findings):
/// a failed import's error must not outlive a destination change, and a new
/// import request must never be swallowed by a still-presented sheet.
@Suite("Workspace Package Import Review State")
struct WorkspacePackageImportReviewStateTests {

    @Test("choosing a new destination clears a stale import error")
    func destinationChangeClearsStaleImportError() {
        var state = WorkspacePackageImportReviewState()
        state.importFinished(.failure(WorkspacePackageImportError.destinationAlreadyExists("/tmp/taken")))
        #expect(!state.statusMessage.isEmpty)

        state.destinationChosen(URL(fileURLWithPath: "/tmp/elsewhere"))

        #expect(state.statusMessage.isEmpty)
        #expect(state.destinationParentURL?.path == "/tmp/elsewhere")
    }

    @Test("an unreadable package reports a status message")
    func unreadablePackageReportsStatus() {
        var state = WorkspacePackageImportReviewState()
        state.planLoaded(nil)
        #expect(!state.statusMessage.isEmpty)
        #expect(!state.canImport)
    }
}

@Suite("Workspace Package Import Sheet Presentation")
struct WorkspacePackageImportSheetPresentationTests {

    private func request(_ name: String) -> WorkspacePackageImportRequest {
        WorkspacePackageImportRequest(url: URL(fileURLWithPath: "/tmp/\(name).astra-share"))
    }

    @Test("a request while idle presents immediately")
    func requestWhileIdlePresentsImmediately() {
        var sheet = WorkspacePackageImportSheetPresentation()
        let first = request("first")
        sheet.request(first)
        #expect(sheet.presented?.id == first.id)
        #expect(sheet.queued.isEmpty)
    }

    @Test("a request while a sheet is presented dismisses it and re-presents the new package")
    func requestWhilePresentedReplacesAfterDismissal() {
        var sheet = WorkspacePackageImportSheetPresentation()
        sheet.request(request("first"))

        // File > Import Workspace… again while the first sheet (for example
        // its completed-import summary) is still on screen.
        let second = request("second")
        sheet.request(second)

        // The presented sheet is dismissed rather than mutated in place…
        #expect(sheet.presented == nil)

        // …and the new request presents once the dismissal settles.
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == second.id)
        #expect(sheet.queued.isEmpty)
    }

    @Test("dismissal with nothing queued stays dismissed")
    func plainDismissalStaysDismissed() {
        var sheet = WorkspacePackageImportSheetPresentation()
        sheet.request(request("only"))
        sheet.presented = nil
        sheet.sheetDismissed()
        #expect(sheet.presented == nil)
    }

    @Test("a newer request during an in-flight dismissal jumps ahead without losing what was already queued")
    func newerRequestDuringDismissalWins() {
        var sheet = WorkspacePackageImportSheetPresentation()
        sheet.request(request("first"))
        let second = request("second")
        sheet.request(second)
        let third = request("third")
        sheet.request(third)

        // "third" jumps ahead of "second" — it's the request the user just
        // made — but "second" is not dropped; it simply waits its turn.
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == third.id)
        #expect(sheet.queued.map(\.id) == [second.id])

        sheet.presented = nil
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == second.id)
        #expect(sheet.queued.isEmpty)
    }

    @Test("a multi-package selection presents the first and drains the rest in order")
    func multiSelectionDrainsInOrder() {
        var sheet = WorkspacePackageImportSheetPresentation()
        let batch = ["a", "b", "c"].map(request)
        sheet.request(batch)

        #expect(sheet.presented?.id == batch[0].id)
        #expect(sheet.queued.map(\.id) == [batch[1].id, batch[2].id])

        sheet.presented = nil
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == batch[1].id)
        #expect(sheet.queued.map(\.id) == [batch[2].id])

        sheet.presented = nil
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == batch[2].id)
        #expect(sheet.queued.isEmpty)
    }

    @Test("a fresh request during a multi-package drain jumps the remaining queue")
    func freshRequestDuringDrainJumpsQueue() {
        var sheet = WorkspacePackageImportSheetPresentation()
        let firstBatch = ["a", "b"].map(request)
        sheet.request(firstBatch)
        #expect(sheet.presented?.id == firstBatch[0].id)

        // Import Workspace… invoked again mid-drain (reviewing "a", "b" still queued).
        let interrupting = request("z")
        sheet.request(interrupting)
        #expect(sheet.presented == nil)

        // The just-requested package wins the interruption…
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == interrupting.id)
        // …and the earlier batch's remainder still finishes afterward.
        #expect(sheet.queued.map(\.id) == [firstBatch[1].id])

        sheet.presented = nil
        sheet.sheetDismissed()
        #expect(sheet.presented?.id == firstBatch[1].id)
    }

    @Test("ContentView routes package imports through the presentation queue")
    func contentViewRoutesThroughPresentationQueue() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(
            "packageImportPresentation.request(partition.packageURLs.map(WorkspacePackageImportRequest.init(url:)))"
        ))
        #expect(source.contains("onDismiss: { packageImportPresentation.sheetDismissed() }"))
        // The raw sheet item must not be assigned outside the queue, or a
        // request arriving while a sheet is up gets silently dropped again.
        #expect(!source.contains("pendingPackageImport"))
    }
}
