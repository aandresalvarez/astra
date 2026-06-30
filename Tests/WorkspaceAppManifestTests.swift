import Foundation
import SwiftData
import Testing
@testable import ASTRA

// F1 scope: this suite covers WorkspaceAppManifest Codable + WorkspaceAppManifestValidator only.
// The susom source file also exercised WorkspaceAppService (encoding/digest/CRUD),
// WorkspaceAppContractRegistry, WorkspaceAppStorageService, and WorkspaceAppWebViewBridge;
// those tests re-land with their subsystems in F2 / F3 / F5.
@Suite("Workspace App Manifest")
struct WorkspaceAppManifestTests {
    @Test("valid manifest passes validation")
    func validManifestPassesValidation() {
        let report = WorkspaceAppManifestValidator.validate(Self.reconciliationManifest())

        #expect(report.isValid)
        #expect(report.blockers.isEmpty)
    }

    @Test("manifest validation rejects duplicate IDs and unknown requirement references")
    func validationRejectsDuplicateIDsAndUnknownRequirementRefs() {
        var manifest = Self.reconciliationManifest()
        manifest.requirements.append(manifest.requirements[0])
        manifest.sources.append(WorkspaceAppSource(
            id: "orphan_source",
            requirementRef: "missingRequirement",
            operation: "runReadOnlyQuery"
        ))

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/requirements/2/id" && $0.message.contains("duplicated")
        })
        #expect(report.blockers.contains {
            $0.path == "/sources/2/requirementRef" && $0.message.contains("unknown requirement")
        })
    }

    @Test("manifest validation rejects BigQuery query-only capability read sources")
    func validationRejectsBigQueryQueryOnlyCapabilityReadSources() {
        var manifest = Self.reconciliationManifest()
        manifest.sources[0] = WorkspaceAppSource(
            id: "latest_candidates",
            requirementRef: "sourceWarehouse",
            operation: "runReadOnlyQuery",
            query: "SELECT * FROM clinical.enrollment_candidates LIMIT 100"
        )

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/sources/0/query" && $0.message.contains("must not embed SQL")
        })
        #expect(report.blockers.contains {
            $0.path == "/sources/0/tableRef" && $0.message.contains("structured tableRef")
        })
    }

    @Test("manifest validation treats default tabular query reads as BigQuery")
    func validationTreatsDefaultTabularQueryReadsAsBigQuery() {
        var manifest = Self.reconciliationManifest()
        manifest.requirements[0] = WorkspaceAppRequirement(
            id: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["describeTable", "runReadOnlyQuery"]
        )
        manifest.sources[0] = WorkspaceAppSource(
            id: "latest_candidates",
            requirementRef: "sourceWarehouse",
            operation: "runReadOnlyQuery",
            query: "SELECT * FROM clinical.enrollment_candidates LIMIT 100"
        )

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/sources/0/query" && $0.message.contains("must not embed SQL")
        })
        #expect(report.blockers.contains {
            $0.path == "/sources/0/tableRef" && $0.message.contains("structured tableRef")
        })
    }

    @Test("manifest validation allows package tabular query providers without BigQuery table refs")
    func validationAllowsPackageTabularQueryProvidersWithoutBigQueryTableRefs() {
        var manifest = Self.reconciliationManifest()
        manifest.requirements[0] = WorkspaceAppRequirement(
            id: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["describeTable", "runReadOnlyQuery"],
            providerRequired: "warehouseApi"
        )
        manifest.sources[0] = WorkspaceAppSource(
            id: "latest_candidates",
            requirementRef: "sourceWarehouse",
            operation: "runReadOnlyQuery",
            query: "/warehouse/enrollment-candidates"
        )

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(report.isValid)
        #expect(!report.blockers.contains { $0.message.contains("BigQuery") })
    }

    @Test("manifest validation blocks automations that default enabled")
    func validationBlocksEnabledAutomationDefaults() {
        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "daily_refresh",
                type: "schedule",
                enabledByDefault: true,
                action: "refresh"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/automations/0/enabledByDefault"
        })
    }

    @Test("manifest validation rejects invalid automation schedules")
    func validationRejectsInvalidAutomationSchedules() {
        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "fast",
                type: "schedule",
                action: "refresh",
                scheduleType: "interval",
                intervalSeconds: 0
            ),
            WorkspaceAppAutomationSpec(
                id: "weekly",
                type: "schedule",
                action: "refresh",
                scheduleType: "weekly",
                dailyHour: 25,
                dailyMinute: 0,
                weeklyDayOfWeek: 9
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/automations/0/intervalSeconds" && $0.message.contains("positive")
        })
        #expect(report.blockers.contains {
            $0.path == "/automations/1/dailyHour" && $0.message.contains("0 through 23")
        })
        #expect(report.blockers.contains {
            $0.path == "/automations/1/weeklyDayOfWeek" && $0.message.contains("1 through 7")
        })
    }

    @Test("manifest validation rejects view widgets bound to unknown storage")
    func validationRejectsUnknownViewWidgetStorageBindings() {
        var manifest = Self.reconciliationManifest()
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "dashboard",
                type: "dashboard",
                title: "Dashboard",
                table: "missing_table",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "missing_metric",
                        type: "metric",
                        label: "Missing",
                        table: "review_items",
                        field: "missing_field",
                        aggregation: "sum"
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/table" && $0.message.contains("missing_table")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/field" && $0.message.contains("missing_field")
        })
    }

    @Test("manifest validation restricts WebView widgets")
    func validationRestrictsWebViewWidgets() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(id: "export_missing", type: "artifact.export", table: "review_items")
        ]
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "diagram",
                type: "dashboard",
                title: "Diagram",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "unsafe_widget",
                        type: "webView",
                        label: "Unsafe",
                        webRenderer: "customJavaScript",
                        allowedActions: ["missing_action"],
                        requiredAssets: ["/Users/alvaro/private.js"]
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/webRenderer" && $0.message.contains("not allowed")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/allowedActions/0" && $0.message.contains("unknown action")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/requiredAssets/0" && $0.message.contains("portable")
        })
    }

    @Test("manifest validation rejects empty markdown widgets")
    func validationRejectsEmptyMarkdownWidgets() {
        var manifest = Self.reconciliationManifest()
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "overview",
                type: "dashboard",
                title: "Overview",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "instructions",
                        type: "markdown",
                        label: "Instructions",
                        markdownContent: "   "
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/markdownContent" && $0.message.contains("Markdown widget content")
        })
    }

    @Test("manifest validation rejects invalid diagram widgets")
    func validationRejectsInvalidDiagramWidgets() {
        var manifest = Self.reconciliationManifest()
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "overview",
                type: "dashboard",
                title: "Overview",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "process",
                        type: "diagram",
                        label: "Process",
                        diagramContent: "   ",
                        diagramKind: "sequence"
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/diagramContent" && $0.message.contains("Diagram widget content")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/diagramKind" && $0.message.contains("not supported")
        })
    }


    @Test("manifest validation rejects task actions without a goal")
    func validationRejectsTaskActionsWithoutGoal() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "create_review",
                type: "task.createDraft",
                label: "Create Review Task"
            ),
            WorkspaceAppActionSpec(
                id: "run_review",
                type: "task.createAndRun",
                label: "Run Review Task"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/taskGoal" && $0.message.contains("task goal")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/taskGoal" && $0.message.contains("task goal")
        })
    }

    @Test("manifest validation rejects human approval gates without prompts or decisions")
    func validationRejectsInvalidHumanApprovalGates() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "approval_gate",
                type: "gate.humanApproval",
                label: "Approval"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/approvalPrompt" && $0.message.contains("approval prompt")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/approvalDecisions" && $0.message.contains("available decisions")
        })
    }

    @Test("manifest validation rejects invalid expression gates")
    func validationRejectsInvalidExpressionGates() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "expression_gate",
                type: "gate.expression",
                label: "Ready Gate",
                gateOperator: "around"
            ),
            WorkspaceAppActionSpec(
                id: "threshold_gate",
                type: "gate.expression",
                label: "Threshold Gate",
                gateField: "score",
                gateOperator: "greaterThan"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateField" && $0.message.contains("field")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateOperator" && $0.message.contains("not supported")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/gateValue" && $0.message.contains("comparison value")
        })
    }

    @Test("manifest validation rejects invalid agent recommendation gates")
    func validationRejectsInvalidAgentRecommendationGates() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "agent_gate",
                type: "gate.agentRecommendation",
                label: "Agent Gate",
                agentPolicyMode: "automatic",
                agentTokenBudget: 0
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/agentPrompt" && $0.message.contains("agent prompt")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/agentDecisions" && $0.message.contains("available decisions")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/agentPolicyMode" && $0.message.contains("not supported")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/agentTokenBudget" && $0.message.contains("positive")
        })
    }

    @Test("manifest validation rejects invalid pipeline step references")
    func validationRejectsInvalidPipelineStepReferences() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(id: "refresh", type: "pipeline.run", label: "Refresh", steps: ["refresh", "missing"]),
            WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List", table: "review_items")
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/steps/0" && $0.message.contains("cannot include itself")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/steps/1" && $0.message.contains("unknown action")
        })
    }

    @Test("manifest validation rejects invalid loop bounds and stop conditions")
    func validationRejectsInvalidLoopBoundsAndStopConditions() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "review_loop",
                type: "loop.run",
                label: "Review Loop",
                gateField: " ",
                gateOperator: "equals",
                steps: ["list_items"],
                maxIterations: 0,
                timeoutSeconds: 0,
                delaySeconds: -1
            ),
            WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List", table: "review_items")
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/maxIterations" && $0.message.contains("positive maximum iteration")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/timeoutSeconds" && $0.message.contains("positive timeout")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/delaySeconds" && $0.message.contains("cannot be negative")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateField" && $0.message.contains("stop-condition field")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateValue" && $0.message.contains("comparison value")
        })
    }

    @Test("manifest validation rejects recursive workflow step graphs")
    func validationRejectsRecursiveWorkflowStepGraphs() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "review_loop",
                type: "loop.run",
                label: "Review Loop",
                gateField: "status",
                gateOperator: "equals",
                gateValue: .text("done"),
                steps: ["refresh_pipeline"],
                maxIterations: 3,
                timeoutSeconds: 30
            ),
            WorkspaceAppActionSpec(
                id: "refresh_pipeline",
                type: "pipeline.run",
                label: "Refresh Pipeline",
                steps: ["list_items", "review_loop"]
            ),
            WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List", table: "review_items")
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/steps/0" && $0.message.contains("cycle back to action 'review_loop'")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/steps/1" && $0.message.contains("cycle back to action 'refresh_pipeline'")
        })
    }

    @Test("manifest decoding keeps legacy actions without pipeline steps compatible")
    func manifestDecodingKeepsLegacyActionsWithoutPipelineStepsCompatible() throws {
        let json = """
        {
          "schemaVersion": 1,
          "app": {"id": "legacy", "name": "Legacy", "icon": "square.grid.2x2", "description": "", "tags": [], "archetypes": []},
          "requirements": [],
          "storage": null,
          "sources": [],
          "views": [],
          "actions": [
            {"id": "legacy_action", "type": "task.createDraft", "label": "Create", "taskGoal": "Do work"}
          ],
          "automations": [],
          "permissions": {"reads": [], "writes": [], "externalWrites": [], "defaultMode": "draftOnly"}
        }
        """

        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))

        #expect(manifest.actions.count == 1)
        #expect(manifest.actions[0].steps.isEmpty)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("manifest validation rejects artifact exports with unknown table or format")
    func validationRejectsInvalidArtifactExportBindings() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "export_missing",
                type: "artifact.export",
                label: "Export",
                table: "missing_table",
                exportFormat: "xlsx"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/table" && $0.message.contains("missing_table")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/exportFormat" && $0.message.contains("csv or json")
        })
    }

    @Test("manifest validation rejects storage actions with unknown tables")
    func validationRejectsStorageActionsWithUnknownTables() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "update_missing",
                type: "appStorage.update",
                label: "Update",
                table: "missing_table"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/table" && $0.message.contains("missing_table")
        })
    }

    @Test("manifest validation rejects invalid utility action payloads")
    func validationRejectsInvalidUtilityActionPayloads() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "open_file",
                type: "url.open",
                label: "Open File",
                targetURL: "file:///Users/alvaro1/private.csv"
            ),
            WorkspaceAppActionSpec(
                id: "copy_blank",
                type: "clipboard.copy",
                label: "Copy Blank",
                clipboardText: " "
            ),
            WorkspaceAppActionSpec(
                id: "notify_blank",
                type: "notification.show",
                label: "Notify Blank"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/targetURL" && $0.message.contains("http or https")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/clipboardText" && $0.message.contains("text to copy")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/2/notificationTitle" && $0.message.contains("title or body")
        })
    }

    @Test("manifest validation rejects capability reads without declared sources")
    func validationRejectsCapabilityReadsWithoutDeclaredSources() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "read_missing_source",
                type: "capability.read",
                label: "Read Missing"
            ),
            WorkspaceAppActionSpec(
                id: "read_unknown_source",
                type: "capability.read",
                label: "Read Unknown",
                sourceRef: "unknown_source"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/sourceRef" && $0.message.contains("source reference")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/sourceRef" && $0.message.contains("unknown_source")
        })
    }

    @Test("manifest validation rejects capability writes without requirement or operation")
    func validationRejectsCapabilityWritesWithoutRequirementOrOperation() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "write_missing_requirement",
                type: "capability.write",
                label: "Write Missing",
                operation: "submitCreate"
            ),
            WorkspaceAppActionSpec(
                id: "write_missing_operation",
                type: "capability.write",
                label: "Write Missing Operation",
                requirementRef: "targetRecords"
            ),
            WorkspaceAppActionSpec(
                id: "write_unknown_requirement",
                type: "capability.write",
                label: "Write Unknown",
                requirementRef: "unknownWrite",
                operation: "submitCreate"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/requirementRef" && $0.message.contains("requirement reference")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/operation" && $0.message.contains("operation")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/2/requirementRef" && $0.message.contains("unknownWrite")
        })
    }

    @Test("manifest decoding keeps legacy view specs without widgets compatible")
    func manifestDecodingKeepsLegacyViewSpecsCompatible() throws {
        let json = """
        {
          "schemaVersion": 1,
          "app": {
            "id": "legacy-app",
            "name": "Legacy App",
            "icon": "square.grid.2x2",
            "description": "",
            "tags": [],
            "archetypes": []
          },
          "requirements": [],
          "sources": [],
          "views": [
            {"id": "dashboard", "type": "dashboard", "title": "Dashboard"}
          ],
          "actions": [],
          "automations": [],
          "permissions": {
            "reads": [],
            "writes": [],
            "externalWrites": [],
            "defaultMode": "readOnly"
          }
        }
        """

        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))

        #expect(manifest.views.count == 1)
        #expect(manifest.views[0].table == nil)
        #expect(manifest.views[0].widgets.isEmpty)
    }

    static func reconciliationManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "enrollment-reconciliation",
                name: "Enrollment Reconciliation",
                icon: "checklist.checked",
                description: "Compare warehouse records against REDCap."
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    minVersion: "1.0.0",
                    operations: ["describeTable", "runReadOnlyQuery"],
                    providerHint: "bigQuery",
                    dataClass: "sensitive"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    minVersion: "1.0.0",
                    operations: ["describeProject", "readRecords", "validateRecord"],
                    providerHint: "redcap",
                    dataClass: "sensitive"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "source_record_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "match_status", type: "text", required: true)
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "latest_candidates",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    tableRef: "clinical.enrollment_candidates"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    projectRef: "enrollment-study"
                )
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "dashboard",
                    type: "dashboard",
                    title: "Enrollment Reconciliation",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_count",
                            type: "metric",
                            label: "Review records",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "records_by_status",
                            type: "chart",
                            label: "Records by status",
                            groupBy: "match_status",
                            aggregation: "count"
                        )
                    ]
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "refresh", type: "pipeline", label: "Refresh"),
                WorkspaceAppActionSpec(id: "add_review_item", type: "appStorage.insert", label: "Add Review Item", table: "review_items")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["tabularQuery.read", "recordProject.read"],
                writes: ["appStorage.records"],
                defaultMode: .readOnly
            )
        )
    }
}
