import Testing
@testable import ASTRA
import ASTRACore

@Suite("Workspace Pack Settings Presentation")
struct WorkspacePackSettingsPresentationTests {
    @Test("enabled pack row exposes inspectable contribution details")
    func enabledPackRowExposesInspectableContributionDetails() throws {
        let snapshot = AstraPackCatalogSnapshot(
            entries: [Self.entry(Self.devOpsPack(), kind: .builtIn)],
            diagnostics: []
        )

        let presentation = WorkspacePackSettingsPresentation.make(
            snapshot: snapshot,
            enabledPackIDs: ["astra.pack.devops"]
        )

        let row = try #require(presentation.rows.first)
        #expect(presentation.availableCount == 1)
        #expect(presentation.enabledCount == 1)
        #expect(row.id == "astra.pack.devops")
        #expect(row.name == "DevOps Pack")
        #expect(row.sourceLabel == "Built-in")
        #expect(row.versionLabel == "v1.0.0")
        #expect(row.description == "Opinionated defaults for pull request queues.")
        #expect(row.iconSystemName == "arrow.triangle.pull")
        #expect(row.isEnabled)
        #expect(row.shelfSummary == "Plan, Files")
        #expect(row.templateSummary == "PR / CI Review")
        #expect(row.capabilitySummary == "github-workflow")
        #expect(row.policySummary == "No restrictions")
    }

    @Test("selection policy normalizes enabled pack IDs")
    func selectionPolicyNormalizesEnabledPackIDs() {
        let enabled = WorkspacePackSelectionPolicy.enabledPackIDs(
            current: [" astra.pack.devops ", "", "astra.pack.devops"],
            setting: " vertical.incident ",
            isEnabled: true
        )
        #expect(enabled == ["astra.pack.devops", "vertical.incident"])

        let disabled = WorkspacePackSelectionPolicy.enabledPackIDs(
            current: enabled,
            setting: "astra.pack.devops",
            isEnabled: false
        )
        #expect(disabled == ["vertical.incident"])
    }

    @Test("missing enabled pack remains visible for cleanup")
    func missingEnabledPackRemainsVisibleForCleanup() throws {
        let presentation = WorkspacePackSettingsPresentation.make(
            snapshot: AstraPackCatalogSnapshot(entries: [], diagnostics: []),
            enabledPackIDs: ["vertical.missing"]
        )

        let row = try #require(presentation.rows.first)
        #expect(presentation.availableCount == 1)
        #expect(presentation.enabledCount == 1)
        #expect(row.id == "vertical.missing")
        #expect(row.name == "vertical.missing")
        #expect(row.sourceLabel == "Missing")
        #expect(row.isEnabled)
        #expect(row.description == "This pack is enabled in the workspace but was not found in the catalog.")
    }

    @Test("catalog diagnostics are shaped for settings")
    func catalogDiagnosticsAreShapedForSettings() throws {
        let source = AstraPackSource(
            kind: .local,
            manifestURL: nil,
            rootURL: nil,
            displayName: "Local Packs",
            rawData: nil
        )
        let snapshot = AstraPackCatalogSnapshot(
            entries: [],
            diagnostics: [
                AstraPackCatalogDiagnostic(
                    code: .malformedManifest,
                    source: source,
                    message: "Could not decode ASTRA pack manifest.",
                    validationIssues: []
                )
            ]
        )

        let presentation = WorkspacePackSettingsPresentation.make(snapshot: snapshot, enabledPackIDs: [])

        let diagnostic = try #require(presentation.diagnostics.first)
        #expect(diagnostic.title == "Local pack issue")
        #expect(diagnostic.detail == "Could not decode ASTRA pack manifest.")
    }

    private static func devOpsPack() -> AstraPackManifest {
        AstraPackManifest(
            id: "astra.pack.devops",
            name: "DevOps Pack",
            version: "1.0.0",
            coreAPIVersion: "1.0",
            description: "Opinionated defaults for pull request queues.",
            capabilityPackageIDs: ["github-workflow"],
            shelfDefaults: [
                AstraPackShelfDefault(
                    id: "plan",
                    title: "Plan",
                    kind: "nativeShelf",
                    capabilityPackageIDs: ["github-workflow"]
                ),
                AstraPackShelfDefault(
                    id: "files",
                    title: "Files",
                    kind: "nativeShelf",
                    capabilityPackageIDs: ["github-workflow"]
                )
            ],
            appTemplates: [
                AstraPackAppTemplate(
                    id: "pr-ci-review",
                    name: "PR / CI Review",
                    contributionKind: "workspaceAppTemplate",
                    templateID: "workspace-app.pr-ci-review",
                    capabilityPackageIDs: ["github-workflow"]
                )
            ],
            branding: AstraPackBranding(
                accentColor: "#3B82F6",
                iconSystemName: "arrow.triangle.pull",
                displayName: "DevOps"
            )
        )
    }

    private static func entry(
        _ manifest: AstraPackManifest,
        kind: AstraPackSource.Kind
    ) -> AstraPackCatalogEntry {
        AstraPackCatalogEntry(
            manifest: manifest,
            source: AstraPackSource(
                kind: kind,
                manifestURL: nil,
                rootURL: nil,
                displayName: kind == .builtIn ? "Built-in Packs" : "Local Packs",
                rawData: nil
            )
        )
    }
}
