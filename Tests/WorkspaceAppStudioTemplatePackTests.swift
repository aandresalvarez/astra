import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Workspace App Studio Template Packs")
struct WorkspaceAppStudioTemplatePackTests {
    final class ScriptedRunner {
        private(set) var calls: [(prompt: String, workspacePath: String)] = []
        private let output: AgentUtilityRunResult

        init(output: AgentUtilityRunResult) {
            self.output = output
        }

        var runner: WorkspaceAppStudioPromptRunner {
            { [self] prompt, workspacePath, _ in
                calls.append((prompt, workspacePath))
                return output
            }
        }
    }

    @Test("enabled pack template appears in template catalog")
    func enabledPackTemplateAppearsInTemplateCatalog() throws {
        let snapshot = Self.snapshot(entries: [
            Self.entry(
                packID: "astra.pack.devops",
                packName: "DevOps Pack",
                sourceKind: .builtIn,
                templates: [
                    Self.template(
                        id: "pr-review-board",
                        name: "PR Review Board",
                        templateID: "workspace-app.pr-review-board",
                        capabilityPackageIDs: ["github-workflow"]
                    )
                ],
                branding: AstraPackBranding(
                    accentColor: "#4B8BFF",
                    iconSystemName: "arrow.triangle.pull",
                    displayName: "DevOps"
                )
            )
        ])

        let catalog = WorkspaceAppTemplatePackCatalog(
            snapshot: snapshot,
            enabledPackIDs: ["astra.pack.devops"]
        )

        let descriptor = try #require(catalog.templates.first)
        #expect(catalog.templates.count == 1)
        #expect(descriptor.id == "astra.pack.devops/pr-review-board")
        #expect(descriptor.packID == "astra.pack.devops")
        #expect(descriptor.packDisplayName == "DevOps Pack")
        #expect(descriptor.templateContributionID == "pr-review-board")
        #expect(descriptor.templateID == "workspace-app.pr-review-board")
        #expect(descriptor.displayName == "PR Review Board")
        #expect(descriptor.packSource.kind == .builtIn)
        #expect(descriptor.capabilityPackageIDs == ["github-workflow"])
        #expect(descriptor.branding?.displayName == "DevOps")
    }

    @Test("disabled pack template is hidden")
    func disabledPackTemplateIsHidden() {
        let snapshot = Self.snapshot(entries: [
            Self.entry(
                packID: "astra.pack.devops",
                templates: [Self.template(id: "pr-review-board")]
            ),
            Self.entry(
                packID: "astra.pack.research",
                templates: [Self.template(id: "paper-review")]
            )
        ])

        let catalog = WorkspaceAppTemplatePackCatalog(
            snapshot: snapshot,
            enabledPackIDs: ["astra.pack.research"]
        )

        #expect(catalog.templates.map(\.packID) == ["astra.pack.research"])
        #expect(catalog.templates.map(\.templateContributionID) == ["paper-review"])
    }

    @Test("template requirements are recorded as provenance and do not grant capability contracts")
    func templateRequirementsAreRecordedButNotGranted() async throws {
        let descriptor = try #require(WorkspaceAppTemplatePackCatalog(
            snapshot: Self.snapshot(entries: [
                Self.entry(
                    packID: "astra.pack.private",
                    templates: [
                        Self.template(
                            id: "private-queue",
                            name: "Private Queue",
                            capabilityPackageIDs: ["private-workflow"]
                        )
                    ]
                )
            ]),
            enabledPackIDs: ["astra.pack.private"]
        ).templates.first)
        #expect(descriptor.capabilityPackageIDs == ["private-workflow"])

        let manifest = Self.manifestReferencingUndeclaredContract("capability.private-workflow.read")
        let runner = ScriptedRunner(output: Self.manifestBlock(Self.json(manifest)))

        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Use the private queue pack template.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 0,
            contractFamilies: WorkspaceAppContractRegistry().families,
            templateContext: WorkspaceAppStudioTemplateContext(packTemplate: descriptor),
            runner: runner.runner
        )

        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].prompt.contains("PACK TEMPLATE"))
        #expect(runner.calls[0].prompt.contains("Private Queue"))
        #expect(result.origin == .deterministicFallback)
        #expect(result.providerFailure?.contains("capability.private-workflow.read") == true)
    }

    @Test("legacy generation has no pack dependency")
    func legacyGenerationHasNoPackDependency() async {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let runner = ScriptedRunner(output: Self.manifestBlock(Self.json(manifest)))

        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            runner: runner.runner
        )

        #expect(result.accepted)
        #expect(result.origin == .model)
        #expect(runner.calls.count == 1)
        #expect(!runner.calls[0].prompt.contains("PACK TEMPLATE"))
    }

    private static func snapshot(entries: [AstraPackCatalogEntry]) -> AstraPackCatalogSnapshot {
        AstraPackCatalogSnapshot(entries: entries, diagnostics: [])
    }

    private static func entry(
        packID: String,
        packName: String = "Test Pack",
        sourceKind: AstraPackSource.Kind = .local,
        templates: [AstraPackAppTemplate],
        branding: AstraPackBranding? = nil
    ) -> AstraPackCatalogEntry {
        AstraPackCatalogEntry(
            manifest: AstraPackManifest(
                id: packID,
                name: packName,
                version: "1.0.0",
                coreAPIVersion: "1.0",
                description: "Template pack test fixture.",
                appTemplates: templates,
                branding: branding
            ),
            source: AstraPackSource(
                kind: sourceKind,
                manifestURL: URL(fileURLWithPath: "/tmp/\(packID).json"),
                rootURL: URL(fileURLWithPath: "/tmp"),
                displayName: "Fixture Packs",
                rawData: nil
            )
        )
    }

    private static func template(
        id: String,
        name: String = "Test Template",
        contributionKind: String = "workspaceApp",
        templateID: String = "workspace-app.test-template",
        capabilityPackageIDs: [String] = []
    ) -> AstraPackAppTemplate {
        AstraPackAppTemplate(
            id: id,
            name: name,
            contributionKind: contributionKind,
            templateID: templateID,
            capabilityPackageIDs: capabilityPackageIDs
        )
    }

    private static func ok(_ output: String) -> AgentUtilityRunResult {
        AgentUtilityRunResult(exitCode: 0, output: output, error: "")
    }

    private static func manifestBlock(_ json: String) -> AgentUtilityRunResult {
        ok("ASTRA_APP_MANIFEST\n\(json)\nEND_ASTRA_APP_MANIFEST")
    }

    private static func json(_ manifest: WorkspaceAppManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(manifest), encoding: .utf8)!
    }

    private static func manifestReferencingUndeclaredContract(_ contract: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "private-queue",
                name: "Private Queue",
                description: "Reads from a private pack capability."
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "privateCapability",
                    contract: contract,
                    operations: ["default"],
                    reason: "Read private queue rows."
                )
            ],
            sources: [
                WorkspaceAppSource(
                    id: "privateRows",
                    requirementRef: "privateCapability",
                    operation: "default",
                    mode: "read"
                )
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "readPrivateRows",
                    type: "capability.read",
                    label: "Read Private Rows",
                    sourceRef: "privateRows"
                )
            ],
            permissions: WorkspaceAppPermissions(reads: [contract], defaultMode: .draftOnly),
            html: "<div id=\"app\">Private Queue</div>"
        )
    }
}
