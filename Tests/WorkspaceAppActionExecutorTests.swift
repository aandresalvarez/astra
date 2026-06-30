import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Action Executor")
struct WorkspaceAppActionExecutorTests {
    @MainActor
    @Test("app storage insert and query actions create durable app runs")
    func appStorageInsertAndQueryActionsCreateDurableRuns() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let insertResult = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )
        let queryResult = try WorkspaceAppActionExecutor().execute(
            actionID: "listItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(table: "items"),
            modelContext: fixture.context
        )

        #expect(insertResult.run.status == .completed)
        #expect(insertResult.outputSummary == "Inserted 1 record into items.")
        #expect(queryResult.rows.count == 1)
        #expect(queryResult.rows[0]["name"] == .text("Apples"))
        #expect(queryResult.run.status == .completed)
        #expect(fixture.app.lastRunAt != nil)

        let runs = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.appID == fixture.app.id && $0.workspaceID == fixture.workspace.id })

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.count == 4)
        #expect(events.contains { $0.type == "workspaceApp.action.started" && $0.actionID == "addItem" })
        #expect(events.contains { $0.type == "workspaceApp.action.completed" && $0.actionID == "listItems" })
    }

    @MainActor
    @Test("app storage update and delete actions mutate records with primary key input")
    func appStorageUpdateAndDeleteActionsMutateRecordsWithPrimaryKeyInput() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let updateResult = try WorkspaceAppActionExecutor().execute(
            actionID: "updateItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Oranges"),
                    "category": .text("Citrus")
                ]
            ),
            modelContext: fixture.context
        )
        let queryResult = try WorkspaceAppActionExecutor().execute(
            actionID: "listItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(table: "items"),
            modelContext: fixture.context
        )

        #expect(updateResult.outputSummary == "Updated 1 record in items.")
        #expect(queryResult.rows.count == 1)
        #expect(queryResult.rows[0]["name"] == .text("Oranges"))
        #expect(queryResult.rows[0]["category"] == .text("Citrus"))

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Destructive action 'deleteItem' requires explicit confirmation before execution."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "deleteItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text("item-1")]
                ),
                modelContext: fixture.context
            )
        }

        let deleteResult = try WorkspaceAppActionExecutor().execute(
            actionID: "deleteItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: ["id": .text("item-1")],
                confirmedDestructive: true
            ),
            modelContext: fixture.context
        )
        let finalQuery = try WorkspaceAppActionExecutor().execute(
            actionID: "listItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(table: "items"),
            modelContext: fixture.context
        )

        #expect(deleteResult.outputSummary == "Deleted 1 record from items.")
        #expect(finalQuery.rows.isEmpty)
    }

    @MainActor
    @Test("artifact export actions write linked CSV files from app storage")
    func artifactExportActionsWriteLinkedCSVFilesFromAppStorage() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples, Gala"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        #expect(path.hasSuffix("/.astra/apps/grocery-actions/exports/items.csv"))
        #expect(csv == "id,name,category\nitem-1,\"Apples, Gala\",Produce\n")
        #expect(result.outputSummary == "Exported items.csv.")

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.artifact.exported" &&
            event.payload.contains("items.csv")
        })
    }

    @MainActor
    @Test("artifact CSV exports literalize spreadsheet formula prefixes")
    func artifactCSVExportsLiteralizeSpreadsheetFormulaPrefixes() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let rows: [(id: String, name: String, category: String)] = [
            ("item-eq", "=2+3", "+SUM(A1:A2)"),
            ("item-minus", "-10", "@NOW()"),
            ("item-tab", "\t=2+3", "  =2+3"),
            ("item-cr", "\r=2+3", "Plain"),
            ("item-nbsp", "\u{00A0}=2+3", "Plain"),
            ("item-tab-text", "\tPlain", "Plain"),
            ("item-cr-text", "\rPlain", "Plain")
        ]
        for row in rows {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: [
                        "id": .text(row.id),
                        "name": .text(row.name),
                        "category": .text(row.category)
                    ]
                ),
                modelContext: fixture.context
            )
        }

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        #expect(csv.contains("\nitem-eq,'=2+3,'+SUM(A1:A2)\n"))
        #expect(!csv.contains("\nitem-eq,=2+3,+SUM(A1:A2)\n"))
        #expect(csv.contains("\nitem-minus,'-10,'@NOW()\n"))
        #expect(!csv.contains("\nitem-minus,-10,@NOW()\n"))
        #expect(csv.contains("\nitem-tab,'\t=2+3,'  =2+3\n"))
        #expect(!csv.contains("\nitem-tab,\t=2+3,  =2+3\n"))
        #expect(csv.contains("\nitem-cr,\"'\r=2+3\",Plain\n"))
        #expect(!csv.contains("\nitem-cr,\"\r=2+3\",Plain\n"))
        #expect(csv.contains("\nitem-nbsp,'\u{00A0}=2+3,Plain\n"))
        #expect(!csv.contains("\nitem-nbsp,\u{00A0}=2+3,Plain\n"))
        #expect(csv.contains("\nitem-tab-text,\tPlain,Plain\n"))
        #expect(!csv.contains("\nitem-tab-text,'\tPlain,Plain\n"))
        #expect(csv.contains("\nitem-cr-text,\"\rPlain\",Plain\n"))
        #expect(!csv.contains("\nitem-cr-text,\"'\rPlain\",Plain\n"))
    }

    @MainActor
    @Test("artifact CSV exports preserve typed negative numeric storage values")
    func artifactCSVExportsPreserveTypedNegativeNumericStorageValues() throws {
        let fixture = try Self.makePublishedApp(
            permissionMode: .draftOnly,
            manifest: Self.metricExportManifest(permissionMode: .draftOnly)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addMetric",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "metrics",
                record: [
                    "id": .text("metric-1"),
                    "count": .integer(-10),
                    "delta": .real(-2.5),
                    "textFormula": .text("=2+3"),
                    "textNegativeInteger": .text("-10"),
                    "textNegativeReal": .text("-2.5")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportMetrics",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        #expect(csv == """
        id,count,delta,textFormula,textNegativeInteger,textNegativeReal
        metric-1,-10,-2.5,'=2+3,'-10,'-2.5

        """)
        #expect(!csv.contains("metric-1,'-10,'-2.5"))
    }

    @MainActor
    @Test("artifact CSV exports preserve declared column headers")
    func artifactCSVExportsPreserveDeclaredColumnHeaders() throws {
        let fixture = try Self.makePublishedApp(
            permissionMode: .draftOnly,
            manifest: Self.scoredExportManifest(permissionMode: .draftOnly)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addScore",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "scores",
                record: [
                    "id": .text("score-1"),
                    "-score": .text("=2+3"),
                    "formulaText": .text("-10")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportScores",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        #expect(csv == """
        id,-score,formulaText
        score-1,'=2+3,'-10

        """)
        #expect(!csv.hasPrefix("id,'-score,formulaText"))
    }

    @MainActor
    @Test("artifact export actions write linked JSON files from app storage")
    func artifactExportActionsWriteLinkedJSONFilesFromAppStorage() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(exportFormat: "json"),
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rows = try JSONDecoder().decode([[String: WorkspaceAppStorageValue]].self, from: data)
        #expect(path.hasSuffix("/.astra/apps/grocery-actions/exports/items.json"))
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Apples"))
    }

    @MainActor
    @Test("task create draft actions create linked AgentTask drafts")
    func taskCreateDraftActionsCreateLinkedAgentTaskDrafts() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "createReviewTask",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first {
            $0.id == result.run.linkedTaskID
        })
        #expect(task.status == .draft)
        #expect(task.workspace?.id == fixture.workspace.id)
        #expect(task.title == "Review grocery records")
        #expect(task.goal == "Review the grocery records and propose the next shopping task.")
        #expect(task.inputs.contains("Created from Workspace App 'Grocery Actions' (grocery-actions)."))
        #expect(result.outputSummary == "Created draft task 'Review grocery records'.")
        #expect(result.run.status == .completed)
        #expect(result.run.linkedTaskID == task.id)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.task.created" &&
            event.payload.contains(task.id.uuidString)
        })
    }

    @MainActor
    @Test("utility actions open URLs copy clipboard text and show notifications through audited client")
    func utilityActionsOpenURLsCopyClipboardTextAndShowNotificationsThroughAuditedClient() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let utilityClient = MockWorkspaceAppUtilityActionClient()
        let executor = WorkspaceAppActionExecutor(utilityActionClient: utilityClient)

        let urlResult = try executor.execute(
            actionID: "openDashboard",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        let clipboardResult = try executor.execute(
            actionID: "copySummary",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        let notificationResult = try executor.execute(
            actionID: "showReminder",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        #expect(utilityClient.openedURLs == [URL(string: "https://example.com/grocery")])
        #expect(utilityClient.clipboardTexts == ["Grocery review ready"])
        #expect(utilityClient.notifications == [
            MockWorkspaceAppUtilityActionClient.Notification(
                title: "Review ready",
                body: "Open the review queue before shopping."
            )
        ])
        #expect(urlResult.outputSummary == "Opened https://example.com/grocery.")
        #expect(clipboardResult.outputSummary == "Copied 20 characters to the clipboard.")
        #expect(notificationResult.outputSummary == "Showed notification 'Review ready'.")

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { $0.type == "workspaceApp.url.opened" && $0.payload.contains("example.com") && $0.payload.contains("grocery") })
        #expect(events.contains { $0.type == "workspaceApp.clipboard.copied" && $0.payload.contains("\"characterCount\":20") })
        #expect(events.contains { $0.type == "workspaceApp.notification.shown" && $0.payload.contains("Review ready") })
    }

    @MainActor
    @Test("task create and run actions queue linked AgentTasks")
    func taskCreateAndRunActionsQueueLinkedAgentTasks() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "runReviewTask",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first {
            $0.id == result.run.linkedTaskID
        })
        #expect(task.status == .queued)
        #expect(task.workspace?.id == fixture.workspace.id)
        #expect(task.title == "Run grocery review")
        #expect(task.goal == "Run the grocery review workflow and summarize the required follow-up.")
        #expect(task.inputs.contains("Created from Workspace App 'Grocery Actions' (grocery-actions)."))
        #expect(result.outputSummary == "Queued task 'Run grocery review'.")
        #expect(result.run.status == .completed)
        #expect(result.run.linkedTaskID == task.id)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.task.created" &&
            event.payload.contains(task.id.uuidString)
        })
    }

    @MainActor
    @Test("capability read actions resolve mapped sources")
    func capabilityReadActionsResolveMappedSources() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            requirementID: "warehouse",
            contract: "tabularQuery.read",
            operations: ["runReadOnlyQuery"],
            optional: false,
            status: .mapped,
            implementationID: "bigquery-read-task-backed",
            provider: "bigQuery",
            transport: .taskBacked
        )
        let executor = WorkspaceAppActionExecutor(
            sourceResolver: WorkspaceAppSourceResolver(
                capabilityClient: MockWorkspaceAppCapabilitySourceClient(rowsBySourceID: [
                    "warehouseLatest": [
                        ["participant_id": .text("P-001"), "updated_at": .text("2026-06-05")]
                    ]
                ])
            )
        )

        let result = try executor.execute(
            actionID: "readWarehouse",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(limit: 25),
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.rows == [["participant_id": .text("P-001"), "updated_at": .text("2026-06-05")]])
        #expect(result.outputSummary.contains("warehouseLatest"))
        #expect(result.outputSummary.contains("bigquery-read-task-backed"))

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.capability.read" &&
                $0.payload.contains("\"sourceID\":\"warehouseLatest\"") &&
                $0.payload.contains("\"implementationID\":\"bigquery-read-task-backed\"") &&
                $0.payload.contains("\"provider\":\"bigQuery\"") &&
                $0.payload.contains("\"rowCount\":1")
        })
    }

    @MainActor
    @Test("capability write actions require approval and record audited writes")
    func capabilityWriteActionsRequireApprovalAndRecordAuditedWrites() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .approvalRequired)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            requirementID: "redcapWrite",
            contract: "recordProject.write",
            operations: ["submitCreate"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-write-task-backed",
            provider: "redcap",
            transport: .taskBacked
        )
        let executor = WorkspaceAppActionExecutor(
            capabilityWriteClient: MockWorkspaceAppCapabilityWriteClient(
                result: WorkspaceAppCapabilityWriteResult(outputSummary: "Submitted REDCap create draft.")
            )
        )

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "External write action 'submitRedcapRecord' requires explicit approval before execution."
        )) {
            try executor.execute(
                actionID: "submitRedcapRecord",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                dependencyBindings: [binding],
                input: WorkspaceAppActionInput(record: ["participant_id": .text("P-001")]),
                modelContext: fixture.context
            )
        }

        let result = try executor.execute(
            actionID: "submitRedcapRecord",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(
                record: ["participant_id": .text("P-001")],
                confirmedApproval: true
            ),
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.outputSummary == "Submitted REDCap create draft.")

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.capability.write" &&
                $0.payload.contains("\"requirementID\":\"redcapWrite\"") &&
                $0.payload.contains("\"implementationID\":\"redcap-write-task-backed\"") &&
                $0.payload.contains("\"provider\":\"redcap\"") &&
                $0.payload.contains("\"recordKeys\":\"participant_id\"")
        })
    }

    @MainActor
    @Test("native REDCap write client submits approved capability writes")
    func nativeREDCapWriteClientSubmitsApprovedCapabilityWrites() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .approvalRequired)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        let actionIndex = try #require(manifest.actions.firstIndex { $0.id == "submitRedcapRecord" })
        manifest.actions[actionIndex].sourceRef = "enrollment"
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            requirementID: "redcapWrite",
            contract: "recordProject.write",
            operations: ["submitCreate"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-write-native",
            provider: "redcap",
            transport: .native
        )
        let writer = MockWorkspaceAppREDCapWriter(result: WorkspaceAppCapabilityWriteResult(
            outputSummary: "Submitted REDCap create.",
            rows: [["record_id": .text("P-001")]]
        ))
        let executor = WorkspaceAppActionExecutor(
            capabilityWriteClient: WorkspaceAppNativeCapabilityWriteClient(redcapWriter: writer)
        )

        let result = try executor.execute(
            actionID: "submitRedcapRecord",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(
                record: ["participant_id": .text("P-001")],
                confirmedApproval: true
            ),
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.outputSummary == "Submitted REDCap create.")
        #expect(result.rows == [["record_id": .text("P-001")]])
        #expect(writer.requests == [
            WorkspaceAppREDCapRequest(
                operation: "submitCreate",
                projectRef: "enrollment",
                sourceID: nil,
                parameters: [:],
                record: ["participant_id": .text("P-001")]
            )
        ])

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.capability.write" &&
                $0.payload.contains("\"implementationID\":\"redcap-write-native\"") &&
                $0.payload.contains("\"provider\":\"redcap\"")
        })
    }

    @MainActor
    @Test("executeAsync performs a real REDCap submit through the async client + HTTP transport")
    func executeAsyncPerformsRealSubmit() async throws {
        let fixture = try Self.makePublishedApp(permissionMode: .approvalRequired)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        let actionIndex = try #require(manifest.actions.firstIndex { $0.id == "submitRedcapRecord" })
        manifest.actions[actionIndex].sourceRef = "enrollment"
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id, appID: fixture.app.id, appLogicalID: fixture.app.logicalID,
            requirementID: "redcapWrite", contract: "recordProject.write", operations: ["submitCreate"],
            optional: false, status: .mapped, implementationID: "redcap-write-native", provider: "redcap", transport: .native
        )
        let http = MockConnectorHTTPTransport(body: Data(#"{"count":1}"#.utf8), status: 200)
        let asyncClient = WorkspaceAppNativeAsyncCapabilityWriteClient(redcapTransport: { _ in
            WorkspaceAppREDCapHTTPTransport(endpoint: URL(string: "https://redcap.example.org/api/")!, token: "TKN", transport: http)
        })
        let executor = WorkspaceAppActionExecutor(asyncCapabilityWriteClient: asyncClient)

        let result = try await executor.executeAsync(
            actionID: "submitRedcapRecord", app: fixture.app, workspace: fixture.workspace, manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(record: ["participant_id": .text("P-001")], confirmedApproval: true),
            modelContext: fixture.context
        )
        #expect(result.run.status == .completed)
        #expect(result.outputSummary.contains("Imported 1 record"))
        // The real REDCap import request was actually built + sent through the transport.
        #expect(http.lastRequest?.httpMethod == "POST")
        let body = http.lastRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("content=record"))
    }

    @MainActor
    @Test("executeAsync refuses a submit when no connector transport is configured (no silent fake)")
    func executeAsyncRefusesUnconfigured() async throws {
        let fixture = try Self.makePublishedApp(permissionMode: .approvalRequired)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        let actionIndex = try #require(manifest.actions.firstIndex { $0.id == "submitRedcapRecord" })
        manifest.actions[actionIndex].sourceRef = "enrollment"
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id, appID: fixture.app.id, appLogicalID: fixture.app.logicalID,
            requirementID: "redcapWrite", contract: "recordProject.write", operations: ["submitCreate"],
            optional: false, status: .mapped, implementationID: "redcap-write-native", provider: "redcap", transport: .native
        )
        // Default executor → async client's redcapTransport returns nil → cleanly unavailable.
        await #expect(throws: (any Error).self) {
            try await WorkspaceAppActionExecutor().executeAsync(
                actionID: "submitRedcapRecord", app: fixture.app, workspace: fixture.workspace, manifest: manifest,
                dependencyBindings: [binding],
                input: WorkspaceAppActionInput(record: ["participant_id": .text("P-001")], confirmedApproval: true),
                modelContext: fixture.context
            )
        }
    }

    @Test("native REDCap write client validates drafts locally")
    func nativeREDCapWriteClientValidatesDraftsLocally() throws {
        let action = WorkspaceAppActionSpec(
            id: "validateRedcap",
            type: "capability.write",
            label: "Validate REDCap",
            requirementRef: "redcapWrite",
            operation: "validateWrite"
        )
        let requirement = WorkspaceAppRequirement(
            id: "redcapWrite",
            contract: "recordProject.write",
            operations: ["validateWrite"],
            providerHint: "redcap"
        )
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: UUID(),
            appID: UUID(),
            appLogicalID: "redcap-app",
            requirementID: "redcapWrite",
            contract: "recordProject.write",
            operations: ["validateWrite"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-write-native",
            provider: "redcap",
            transport: .native
        )

        let result = try WorkspaceAppREDCapWriteClient().write(
            action: action,
            requirement: requirement,
            binding: binding,
            input: WorkspaceAppActionInput(record: [
                "participant_id": .text("P-001"),
                "status": .text("ready")
            ])
        )

        #expect(result.outputSummary == "Validated REDCap write draft with 2 fields.")
        #expect(result.rows == [["status": .text("valid"), "fieldCount": .integer(2)]])
    }

    @MainActor
    @Test("pipeline actions execute declared steps in one app run")
    func pipelineActionsExecuteDeclaredStepsInOneAppRun() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.run.actionID == "exportPipeline")
        #expect(result.run.linkedArtifactPath?.hasSuffix("/.astra/apps/grocery-actions/exports/items.csv") == true)
        #expect(result.outputSummary.contains("Pipeline 'exportPipeline' completed 2 steps."))
        #expect(result.outputSummary.contains("listItems: Read 1 records from items."))
        #expect(result.outputSummary.contains("exportItems: Exported items.csv."))

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("listItems") })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
        #expect(events.contains { $0.type == "workspaceApp.artifact.exported" && $0.payload.contains("items.csv") })
    }

    @MainActor
    @Test("pipeline binds a step's output rows into the next step (B1)")
    func pipelineBindsStepOutputIntoNextStep() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Seed one record so listItems has a row to bind forward.
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        // bindingPipeline = [listItems (query) -> updateItem (update with NO explicit
        // record)]. Without output binding, updateItem throws missingRecord; with B1 it
        // consumes the row listItems produced and the pipeline completes.
        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "bindingPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.outputSummary.contains("updateItem: Updated 1 record in items."))

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.pipeline.step.completed"
                && $0.payload.contains("updateItem")
                && $0.payload.contains("boundRows")
        })
    }

    @MainActor
    @Test("pipeline suspends on an async agent step and resumes to completion (B2)")
    func pipelineSuspendsOnAgentStepAndResumes() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Seed the record the resumed update step will modify.
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: ["id": .text("item-1"), "name": .text("Apples"), "category": .text("Produce")]
            ),
            modelContext: fixture.context
        )

        // awaitPipeline = [runReviewTask (task.createAndRun) -> updateItem]. Step 0 launches
        // an agent task, so the run must SUSPEND (waiting) with a resume point — not complete.
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "awaitPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(suspended.run.status == .waiting)
        #expect(suspended.run.linkedTaskID != nil)
        #expect(suspended.run.pendingActionID == "awaitPipeline")
        #expect(suspended.run.pendingStepIndex == 1)

        // The awaited task "completes" with an output row; resume binds it into updateItem.
        let resumed = try WorkspaceAppActionExecutor().resume(
            run: suspended.run,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            taskOutputRows: [["id": .text("item-1"), "name": .text("FromTask"), "category": .text("Produce")]],
            modelContext: fixture.context
        )
        #expect(resumed.run.status == .completed)
        #expect(resumed.run.pendingActionID == nil)
        #expect(resumed.outputSummary.contains("Updated 1 record in items."))

        // The resumed update wrote the task's bound output forward.
        let rows = try WorkspaceAppStorageService().records(
            in: "items",
            databaseURL: URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: fixture.workspace.primaryPath,
                appID: fixture.app.logicalID
            )),
            limit: 100
        )
        #expect(rows.first?["name"] == .text("FromTask"))
    }

    @MainActor
    @Test("resumption service resumes a waiting run when its task completes (B2)")
    func resumptionServiceResumesWaitingRun() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: ["id": .text("item-1"), "name": .text("Apples"), "category": .text("Produce")]
            ),
            modelContext: fixture.context
        )
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "awaitPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        let taskID = try #require(suspended.run.linkedTaskID)

        // Simulate the awaited task completing: the resumption service finds the
        // waiting run, loads its manifest, and resumes it to completion.
        let results = WorkspaceAppRunResumptionService().resumeRuns(
            awaitingTaskID: taskID,
            taskOutputRows: [["id": .text("item-1"), "name": .text("FromTask"), "category": .text("Produce")]],
            workspace: fixture.workspace,
            modelContext: fixture.context
        )
        #expect(results.count == 1)
        #expect(results.first?.run.status == .completed)

        // An unknown task id resumes nothing.
        #expect(
            WorkspaceAppRunResumptionService().resumeRuns(
                awaitingTaskID: UUID(),
                workspace: fixture.workspace,
                modelContext: fixture.context
            ).isEmpty
        )
    }

    @MainActor
    @Test("resumption sweep resumes runs only once their awaited task completes (B2-live)")
    func resumptionSweepResumesCompletedTaskRuns() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "awaitQueryPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(suspended.run.status == .waiting)
        let taskID = try #require(suspended.run.linkedTaskID)

        // The launched task is still queued -> the sweep resumes nothing.
        #expect(WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context).isEmpty)

        // Mark the awaited task completed, as the runtime would on finish.
        let task = try #require(
            try fixture.context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == taskID }
        )
        task.status = .completed
        try fixture.context.save()

        // Now the sweep finds the waiting run and resumes it to completion.
        let results = WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context)
        #expect(results.count == 1)
        #expect(results.first?.run.status == .completed)
    }

    @MainActor
    @Test("token accounting counts TOTAL agent spend (input+output), not output-only")
    func appBudgetCountsTotalTokens() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "awaitQueryPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        let taskID = try #require(suspended.run.linkedTaskID)
        let task = try #require(
            try fixture.context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == taskID }
        )
        // A high-INPUT, zero-OUTPUT run still burned provider tokens. Output-only accounting would
        // record 0 (undercounting real spend); total accounting must record the 5000 input tokens.
        let taskRun = TaskRun(task: task)
        taskRun.inputTokens = 5000
        taskRun.outputTokens = 0
        taskRun.tokensUsed = 0
        task.runs.append(taskRun)
        fixture.context.insert(taskRun)
        task.status = .completed
        try fixture.context.save()

        let results = WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context)
        #expect(results.count == 1)
        #expect(results.first?.run.consumedTokens == 5000)
    }

    @MainActor
    @Test("whole-run token budget blocks a resume that overruns (B3)")
    func workflowTokenBudgetBlocksOverrun() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Declared whole-run budget = sum of agent-gate token budgets in the pipeline.
        #expect(WorkspaceAppWorkflowBudget.declaredTokenBudget(
            for: fixture.manifest, pipelineActionID: "budgetPipeline") == 500)
        #expect(WorkspaceAppWorkflowBudget.exceedsBudget(
            consumed: 600, manifest: fixture.manifest, pipelineActionID: "budgetPipeline"))
        #expect(!WorkspaceAppWorkflowBudget.exceedsBudget(
            consumed: 400, manifest: fixture.manifest, pipelineActionID: "budgetPipeline"))

        // budgetPipeline = [runReviewTask -> agentGate]; suspends at the task step.
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "budgetPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(suspended.run.status == .waiting)

        // Resume reporting more consumption than the 500-token budget -> the run is
        // BLOCKED (held for review), not continued to the next step.
        let blocked = try WorkspaceAppActionExecutor().resume(
            run: suspended.run,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            consumedTokens: 600,
            modelContext: fixture.context
        )
        #expect(blocked.run.status == .blocked)
        #expect(blocked.run.consumedTokens == 600)
        #expect(blocked.outputSummary.contains("budget exceeded"))
    }

    @Test("per-app agent budget ceilings trip on token, agent-run, or a fan-out batch that would overrun")
    func appAgentBudgetCeilings() {
        let tokenCap = WorkspaceAppWorkflowBudget.appTokenCeiling
        let runCap = WorkspaceAppWorkflowBudget.appAgentRunCeiling
        #expect(!WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: 0, priorAgentRuns: 0))
        #expect(!WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: tokenCap - 1, priorAgentRuns: runCap - 1))
        #expect(WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: tokenCap, priorAgentRuns: 0))
        // The agent-run limit is about LAUNCHES: one more launch at the cap overruns.
        #expect(WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: 0, priorAgentRuns: runCap))
        // A fan-out of N is preflighted as a batch — under the cap individually, over it together.
        #expect(WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: 0, priorAgentRuns: runCap - 10, launching: 20))
        #expect(!WorkspaceAppWorkflowBudget.exceedsAppAgentBudget(priorTokens: 0, priorAgentRuns: runCap - 10, launching: 5))
    }

    @MainActor
    @Test("a preApproved app at its rolling per-app token ceiling can't launch another agent task")
    func appAgentBudgetBlocksNewLaunch() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Seed prior spend at the per-app token ceiling, within the rolling window. This stands in for
        // a `preApproved` app whose page has already serially triggered enough agent work.
        let prior = WorkspaceAppRun(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            actionID: "seed-run",
            trigger: .user,
            inputSummary: ""
        )
        prior.consumedTokens = WorkspaceAppWorkflowBudget.appTokenCeiling
        prior.status = .completed
        fixture.context.insert(prior)
        try fixture.context.save()

        // budgetPipeline's first step is a task.createAndRun — the per-app gate fires BEFORE launching
        // it, so the run is blocked (held for review) rather than spending more agent tokens.
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "budgetPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        // The blocked run was recorded, and a budget-exceeded audit event was emitted.
        let runs = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
        let pipelineRun = runs.first { $0.actionID == "budgetPipeline" }
        #expect(pipelineRun?.status == .blocked)
        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { $0.type == "workspaceApp.appBudget.exceeded" })

        // Sanity: with NO prior spend the same pipeline suspends normally (the gate doesn't fire).
        let fresh = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "budgetPipeline",
            app: fresh.app,
            workspace: fresh.workspace,
            manifest: fresh.manifest,
            modelContext: fresh.context
        )
        #expect(suspended.run.status == .waiting)
    }

    @MainActor
    @Test("task.fanOut launches N tasks, suspends on a barrier, resumes when all complete (C1)")
    func fanOutSuspendsOnBarrierAndResumesWhenAllComplete() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for id in ["item-1", "item-2"] {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text(id), "name": .text(id), "category": .text("Produce")]
                ),
                modelContext: fixture.context
            )
        }
        // fanOutPipeline = [listItems (2 rows) -> fanOutAction (one task per row, barrier)
        // -> reduceCount]. The fan-out launches 2 tasks and suspends on the SET.
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "fanOutPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(suspended.run.status == .waiting)
        #expect(suspended.run.awaitedTaskIDs.count == 2)
        #expect(suspended.run.pendingStepIndex == 2)

        let tasks = try fixture.context.fetch(FetchDescriptor<AgentTask>())
            .filter { suspended.run.awaitedTaskIDs.contains($0.id) }
        #expect(tasks.count == 2)

        // Only one task completed -> the barrier holds, nothing resumes.
        tasks[0].status = .completed
        try fixture.context.save()
        #expect(WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context).isEmpty)

        // All tasks completed -> the barrier resolves; the run resumes through reduce.
        tasks[1].status = .completed
        try fixture.context.save()
        let results = WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context)
        #expect(results.count == 1)
        #expect(results.first?.run.status == .completed)
        #expect(results.first?.rows.first?["count"] == .integer(2))
    }

    @MainActor
    @Test("manifest validation guards task.fanOut child (C1)")
    func fanOutActionValidation() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        // The fixture's fanOutAction (child = runReviewTask, a task.createAndRun) is valid.
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        // Missing child -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(id: "fan_nochild", type: "task.fanOut"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
        manifest.actions.removeLast()
        // Child that is not a task.createAndRun -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(id: "fan_badchild", type: "task.fanOut", fanOutStep: "listItems"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @MainActor
    @Test("fan-out barrier fails the run (not strands) when an awaited task fails (C1 review)")
    func fanOutBarrierFailsRunWhenAwaitedTaskFails() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for id in ["item-1", "item-2"] {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text(id), "name": .text(id), "category": .text("Produce")]
                ),
                modelContext: fixture.context
            )
        }
        let suspended = try WorkspaceAppActionExecutor().execute(
            actionID: "fanOutPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        let tasks = try fixture.context.fetch(FetchDescriptor<AgentTask>())
            .filter { suspended.run.awaitedTaskIDs.contains($0.id) }
        #expect(tasks.count == 2)
        // One completes, one FAILS -> the barrier can never be satisfied.
        tasks[0].status = .completed
        tasks[1].status = .failed
        try fixture.context.save()
        let results = WorkspaceAppRunResumptionService().resumeCompletedRuns(modelContext: fixture.context)
        #expect(results.isEmpty)
        #expect(suspended.run.status == .failed) // failed, not stranded in .waiting
        #expect(suspended.run.errorMessage?.contains("Fan-out failed") == true)
    }

    @MainActor
    @Test("validation rejects a branch that transitively reaches an async task (C2 review)")
    func branchTransitiveAsyncTargetRejected() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        // asyncInner is a synchronous-looking pipeline that actually contains a task step.
        manifest.actions.append(WorkspaceAppActionSpec(id: "asyncInner", type: "pipeline.run", steps: ["runReviewTask"]))
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "badBranch", type: "gate.branch", gateField: "category", gateOperator: "equals",
            gateValue: .text("x"), steps: ["asyncInner"], thenStep: "asyncInner"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @MainActor
    @Test("validation rejects task.fanOut as a loop step or automation action (C1 review)")
    func fanOutPlacementRejected() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // task.fanOut as a loop step (a loop cannot suspend/resume a barrier).
        var loopManifest = fixture.manifest
        loopManifest.actions.append(WorkspaceAppActionSpec(
            id: "badLoop", type: "loop.run", gateField: "status", gateOperator: "equals",
            gateValue: .text("done"), steps: ["fanOutAction"], maxIterations: 3, timeoutSeconds: 60))
        #expect(!WorkspaceAppManifestValidator.validate(loopManifest).isValid)
        // task.fanOut as a direct automation action.
        var autoManifest = fixture.manifest
        autoManifest.automations.append(WorkspaceAppAutomationSpec(id: "badAuto", type: "manual", action: "fanOutAction"))
        #expect(!WorkspaceAppManifestValidator.validate(autoManifest).isValid)
    }

    @MainActor
    @Test("gate.branch runs the then-step when the upstream predicate passes (C2)")
    func branchSelectsThenStepFromUpstreamData() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for id in ["item-1", "item-2"] {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text(id), "name": .text(id), "category": .text("Produce")]
                ),
                modelContext: fixture.context
            )
        }
        // branchPipeline = [listItems (rows with category=Produce) -> branchAction].
        // predicate category==Produce passes -> thenStep reduceCount folds the rows.
        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "branchPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(result.run.status == .completed)
        #expect(result.rows.first?["count"] == .integer(2))
    }

    @MainActor
    @Test("manifest validation guards gate.branch targets + predicate (C2)")
    func branchActionValidation() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        // The fixture's branchAction is well-formed.
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        // No targets -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "bad_branch", type: "gate.branch", gateField: "category", gateOperator: "equals", gateValue: .text("x")))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
        manifest.actions.removeLast()
        // Target not listed in steps -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "bad_branch2", type: "gate.branch", gateField: "category", gateOperator: "equals",
            gateValue: .text("x"), steps: [], thenStep: "listItems"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @MainActor
    @Test("rows.reduce folds a pipeline's prior step rows into one row (C3)")
    func reduceFoldsPriorStepRows() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for id in ["item-1", "item-2"] {
            _ = try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text(id), "name": .text(id), "category": .text("Produce")]
                ),
                modelContext: fixture.context
            )
        }
        // reducePipeline = [listItems (query -> 2 rows) -> reduceCount (rows.reduce count)].
        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "reducePipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(result.run.status == .completed)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?["count"] == .integer(2))
    }

    @MainActor
    @Test("manifest validation guards rows.reduce strategy + column (C3)")
    func reduceActionValidation() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        // count needs no column -> valid.
        manifest.actions.append(WorkspaceAppActionSpec(id: "count_ok", type: "rows.reduce", reduceStrategy: "count"))
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        // unsupported strategy -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(id: "bad_strategy", type: "rows.reduce", reduceStrategy: "median"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
        manifest.actions.removeLast()
        // sum without a column -> invalid.
        manifest.actions.append(WorkspaceAppActionSpec(id: "sum_nocol", type: "rows.reduce", reduceStrategy: "sum"))
        #expect(!WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("action input binds the first upstream row when no explicit record (B1)")
    func actionInputBindsFirstUpstreamRow() {
        let bound: [[String: WorkspaceAppStorageValue]] = [
            ["id": .text("a")],
            ["id": .text("b")]
        ]
        #expect(WorkspaceAppActionInput().bindingForward(rows: bound).effectiveRecord == ["id": .text("a")])
        #expect(
            WorkspaceAppActionInput(record: ["id": .text("explicit")])
                .bindingForward(rows: bound).effectiveRecord == ["id": .text("explicit")]
        )
        #expect(WorkspaceAppActionInput().effectiveRecord.isEmpty)
    }

    @MainActor
    @Test("pipeline human approval gates suspend to .waiting until approved")
    func pipelineHumanApprovalGatesSuspendUntilApproved() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        // Human gates in a pipeline now SUSPEND to .waiting (the actionable approval queue) rather
        // than blocking — the run pauses pending a human decision and is resumed via resumeWithApproval.
        let waitingResult = try WorkspaceAppActionExecutor().execute(
            actionID: "approvalPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(waitingResult.run.status == .waiting)
        #expect(waitingResult.run.pendingApprovalActionID == "approvalGate")

        let waitingRun = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
            .first { $0.actionID == "approvalPipeline" })
        #expect(waitingRun.status == .waiting)
        #expect(waitingRun.linkedArtifactPath == nil)

        var approvalEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == waitingRun.id }
        #expect(approvalEvents.contains { $0.type == "workspaceApp.run.awaitingApproval" })
        #expect(!approvalEvents.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })

        // Approving resumes the run from the gate to completion.
        let approvedResult = try WorkspaceAppActionExecutor().resumeWithApproval(
            run: waitingRun,
            approved: true,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )
        #expect(approvedResult.run.status == .completed)
        #expect(approvedResult.run.pendingApprovalActionID == nil)
        #expect(approvedResult.outputSummary.contains("exportItems: Exported items.csv."))
        #expect(approvedResult.run.linkedArtifactPath?.contains("items.csv") == true)

        approvalEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == waitingRun.id }
        #expect(approvalEvents.contains { $0.type == "workspaceApp.approval.confirmed" })
        #expect(approvalEvents.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
    }

    @MainActor
    @Test("pipeline approval carries to the following agent task launch")
    func pipelineApprovalCarriesToFollowingAgentTaskLaunch() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .approvalRequired)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var manifest = fixture.manifest
        manifest.actions.append(
            WorkspaceAppActionSpec(
                id: "approvalTaskPipeline",
                type: "pipeline.run",
                label: "Approval Task Pipeline",
                steps: ["approvalGate", "runReviewTask"]
            )
        )

        let waitingResult = try WorkspaceAppActionExecutor().execute(
            actionID: "approvalTaskPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: manifest,
            modelContext: fixture.context
        )
        #expect(waitingResult.run.status == .waiting)
        #expect(waitingResult.run.pendingApprovalActionID == "approvalGate")

        let waitingRun = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
            .first { $0.actionID == "approvalTaskPipeline" })

        let approvedResult = try WorkspaceAppActionExecutor().resumeWithApproval(
            run: waitingRun,
            approved: true,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: manifest,
            modelContext: fixture.context
        )

        #expect(approvedResult.run.status == .waiting)
        #expect(approvedResult.run.pendingApprovalActionID == nil)
        #expect(approvedResult.run.pendingActionID == "approvalTaskPipeline")
        #expect(approvedResult.run.pendingStepIndex == 2)
        #expect(approvedResult.run.linkedTaskID != nil)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == waitingRun.id }
        #expect(events.contains { $0.type == "workspaceApp.approval.confirmed" })
        #expect(events.contains {
            $0.type == "workspaceApp.pipeline.step.suspended" &&
                $0.payload.contains("\"stepID\":\"runReviewTask\"")
        })
    }

    @MainActor
    @Test("pipeline expression gates block until input satisfies condition")
    func pipelineExpressionGatesBlockUntilInputSatisfiesCondition() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        #expect(throws: WorkspaceAppActionExecutionError.gateBlocked("readyGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "readyPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(record: ["status": .text("draft")]),
                modelContext: fixture.context
            )
        }

        let blockedRun = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
            .first { $0.actionID == "readyPipeline" })
        #expect(blockedRun.status == .blocked)
        #expect(blockedRun.linkedArtifactPath == nil)

        var events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == blockedRun.id }
        #expect(events.contains {
            $0.type == "workspaceApp.gate.blocked" &&
                $0.payload.contains("\"field\":\"status\"") &&
                $0.payload.contains("\"actualValue\":\"draft\"") &&
                $0.payload.contains("\"expectedValue\":\"ready\"")
        })
        #expect(!events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })

        let passedResult = try WorkspaceAppActionExecutor().execute(
            actionID: "readyPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(record: ["status": .text("ready")]),
            modelContext: fixture.context
        )

        #expect(passedResult.run.status == .completed)
        #expect(passedResult.outputSummary.contains("readyGate: Expression gate 'readyGate' passed."))
        #expect(passedResult.outputSummary.contains("exportItems: Exported items.csv."))
        #expect(passedResult.run.linkedArtifactPath?.contains("items.csv") == true)

        events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == passedResult.run.id }
        #expect(events.contains { $0.type == "workspaceApp.gate.passed" })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("readyGate") })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
    }

    @MainActor
    @Test("pipeline agent recommendation gates require decision and configured approval")
    func pipelineAgentRecommendationGatesRequireDecisionAndConfiguredApproval() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        #expect(throws: WorkspaceAppActionExecutionError.agentRecommendationRequired("agentGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "agentPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }
        #expect(throws: WorkspaceAppActionExecutionError.gateBlocked("agentGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "agentPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(agentRecommendationDecision: "skip"),
                modelContext: fixture.context
            )
        }
        #expect(throws: WorkspaceAppActionExecutionError.approvalRequired("agentGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "agentPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(agentRecommendationDecision: "proceed"),
                modelContext: fixture.context
            )
        }

        let acceptedResult = try WorkspaceAppActionExecutor().execute(
            actionID: "agentPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                confirmedApproval: true,
                agentRecommendationDecision: "proceed"
            ),
            modelContext: fixture.context
        )

        #expect(acceptedResult.run.status == .completed)
        #expect(acceptedResult.outputSummary.contains("agentGate: Agent recommendation gate 'agentGate' accepted 'proceed'."))
        #expect(acceptedResult.outputSummary.contains("exportItems: Exported items.csv."))
        #expect(acceptedResult.run.linkedArtifactPath?.contains("items.csv") == true)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == acceptedResult.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.agentRecommendation.accepted" &&
                $0.payload.contains("\"decision\":\"proceed\"") &&
                $0.payload.contains("\"policyMode\":\"approvalRequired\"") &&
                $0.payload.contains("\"tokenBudget\":500")
        })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("agentGate") })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
    }

    @MainActor
    @Test("loop actions audit bounded iterations and stop conditions")
    func loopActionsAuditBoundedIterationsAndStopConditions() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let maxIterationsResult = try WorkspaceAppActionExecutor().execute(
            actionID: "boundedLoop",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(record: ["status": .text("pending")]),
            modelContext: fixture.context
        )

        #expect(maxIterationsResult.run.status == .completed)
        #expect(maxIterationsResult.outputSummary.contains("Loop 'boundedLoop' completed 3 iterations; max iterations reached."))
        #expect(maxIterationsResult.outputSummary.contains("iteration 3 listItems: Read 1 records from items."))

        let maxEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == maxIterationsResult.run.id }
        #expect(maxEvents.filter { $0.type == "workspaceApp.loop.iteration.started" }.count == 3)
        #expect(maxEvents.filter { $0.type == "workspaceApp.loop.iteration.completed" }.count == 3)
        #expect(maxEvents.filter { $0.type == "workspaceApp.loop.step.completed" }.count == 3)
        #expect(maxEvents.contains {
            $0.type == "workspaceApp.loop.iteration.completed" &&
                $0.payload.contains("\"iteration\":3") &&
                $0.payload.contains("\"stopConditionMet\":false")
        })

        let stoppedResult = try WorkspaceAppActionExecutor().execute(
            actionID: "boundedLoop",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(record: ["status": .text("done")]),
            modelContext: fixture.context
        )

        #expect(stoppedResult.run.status == .completed)
        #expect(stoppedResult.outputSummary.contains("Loop 'boundedLoop' completed 1 iterations; stop condition met."))

        let stoppedEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == stoppedResult.run.id }
        #expect(stoppedEvents.filter { $0.type == "workspaceApp.loop.iteration.started" }.count == 1)
        #expect(stoppedEvents.filter { $0.type == "workspaceApp.loop.step.completed" }.count == 1)
        #expect(stoppedEvents.contains {
            $0.type == "workspaceApp.loop.iteration.completed" &&
                $0.payload.contains("\"iteration\":1") &&
                $0.payload.contains("\"stopConditionMet\":true")
        })
    }

    @MainActor
    @Test("read-only apps block local write actions and record blocked runs")
    func readOnlyAppsBlockLocalWriteActionsAndRecordBlockedRuns() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Read-only workspace apps cannot perform local write action 'addItem'."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text("item-1"), "name": .text("Apples")]
                ),
                modelContext: fixture.context
            )
        }

        let rows = try WorkspaceAppStorageService().records(
            in: "items",
            databaseURL: URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: fixture.workspace.primaryPath,
                appID: fixture.app.logicalID
            ))
        )
        #expect(rows.isEmpty)

        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .blocked)
        #expect(run.completedAt != nil)
        #expect(run.errorMessage?.contains("Read-only workspace apps") == true)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { $0.type == "workspaceApp.action.blocked" })
    }

    @MainActor
    @Test("read-only apps block task draft actions")
    func readOnlyAppsBlockTaskDraftActions() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Read-only workspace apps cannot perform local write action 'createReviewTask'."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "createReviewTask",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        #expect(try fixture.context.fetch(FetchDescriptor<AgentTask>()).isEmpty)
        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .blocked)
        #expect(run.linkedTaskID == nil)
    }

    @MainActor
    @Test("missing actions fail with a recorded app run")
    func missingActionsFailWithRecordedAppRun() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.missingAction("missing")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "missing",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .failed)
        #expect(run.actionID == "missing")
    }

    @MainActor
    static func makePublishedApp(
        permissionMode: WorkspaceAppPermissionMode,
        manifest: WorkspaceAppManifest? = nil
    ) throws -> (
        root: URL,
        container: ModelContainer,
        context: ModelContext,
        workspace: Workspace,
        app: WorkspaceApp,
        manifest: WorkspaceAppManifest
    ) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Actions", primaryPath: root.path)
        context.insert(workspace)

        let resolvedManifest = manifest ?? groceryManifest(permissionMode: permissionMode)
        let result = try WorkspaceAppService().createApp(
            manifest: resolvedManifest,
            in: workspace,
            modelContext: context
        )

        return (root, container, context, workspace, result.app, resolvedManifest)
    }

    static func metricExportManifest(permissionMode: WorkspaceAppPermissionMode) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "metric-actions",
                name: "Metric Actions",
                icon: "chart.line.uptrend.xyaxis"
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["insertRecord", "queryRecords"]
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "metrics", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "count", type: "integer"),
                    WorkspaceAppStorageColumn(name: "delta", type: "real"),
                    WorkspaceAppStorageColumn(name: "textFormula", type: "text"),
                    WorkspaceAppStorageColumn(name: "textNegativeInteger", type: "text"),
                    WorkspaceAppStorageColumn(name: "textNegativeReal", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "metrics", type: "table", title: "Metrics")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "addMetric",
                    type: "appStorage.insert",
                    label: "Add Metric",
                    requirementRef: "localRecords",
                    operation: "insertRecord"
                ),
                WorkspaceAppActionSpec(
                    id: "exportMetrics",
                    type: "artifact.export",
                    label: "Export Metrics",
                    table: "metrics",
                    exportFormat: "csv"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: permissionMode
            )
        )
    }

    static func scoredExportManifest(permissionMode: WorkspaceAppPermissionMode) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "score-actions",
                name: "Score Actions",
                icon: "number"
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["insertRecord", "queryRecords"]
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "scores", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "-score", type: "text"),
                    WorkspaceAppStorageColumn(name: "formulaText", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "scores", type: "table", title: "Scores")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "addScore",
                    type: "appStorage.insert",
                    label: "Add Score",
                    requirementRef: "localRecords",
                    operation: "insertRecord"
                ),
                WorkspaceAppActionSpec(
                    id: "exportScores",
                    type: "artifact.export",
                    label: "Export Scores",
                    table: "scores",
                    exportFormat: "csv"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: permissionMode
            )
        )
    }

    static func groceryManifest(permissionMode: WorkspaceAppPermissionMode) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-actions",
                name: "Grocery Actions",
                icon: "cart"
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["insertRecord", "queryRecords"]
                ),
                WorkspaceAppRequirement(
                    id: "warehouse",
                    contract: "tabularQuery.read",
                    operations: ["runReadOnlyQuery"],
                    providerHint: "bigQuery"
                ),
                WorkspaceAppRequirement(
                    id: "redcapWrite",
                    contract: "recordProject.write",
                    operations: ["submitCreate"],
                    providerHint: "redcap"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "warehouseLatest",
                    requirementRef: "warehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    tableRef: "clinical.enrollment_candidates"
                )
            ],
            views: [
                WorkspaceAppViewSpec(id: "items", type: "table", title: "Items")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "addItem",
                    type: "appStorage.insert",
                    label: "Add Item",
                    requirementRef: "localRecords",
                    operation: "insertRecord"
                ),
                WorkspaceAppActionSpec(
                    id: "listItems",
                    type: "appStorage.query",
                    label: "List Items",
                    requirementRef: "localRecords",
                    operation: "queryRecords",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "updateItem",
                    type: "appStorage.update",
                    label: "Update Item",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "deleteItem",
                    type: "appStorage.delete",
                    label: "Delete Item",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "createReviewTask",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review grocery records",
                    taskGoal: "Review the grocery records and propose the next shopping task."
                ),
                WorkspaceAppActionSpec(
                    id: "runReviewTask",
                    type: "task.createAndRun",
                    label: "Run Review Task",
                    taskTitle: "Run grocery review",
                    taskGoal: "Run the grocery review workflow and summarize the required follow-up."
                ),
                WorkspaceAppActionSpec(
                    id: "readWarehouse",
                    type: "capability.read",
                    label: "Read Warehouse",
                    requirementRef: "warehouse",
                    operation: "runReadOnlyQuery",
                    sourceRef: "warehouseLatest"
                ),
                WorkspaceAppActionSpec(
                    id: "submitRedcapRecord",
                    type: "capability.write",
                    label: "Submit REDCap Record",
                    requirementRef: "redcapWrite",
                    operation: "submitCreate"
                ),
                WorkspaceAppActionSpec(
                    id: "exportItems",
                    type: "artifact.export",
                    label: "Export Items",
                    table: "items",
                    exportFormat: "csv"
                ),
                WorkspaceAppActionSpec(
                    id: "openDashboard",
                    type: "url.open",
                    label: "Open Dashboard",
                    targetURL: "https://example.com/grocery"
                ),
                WorkspaceAppActionSpec(
                    id: "copySummary",
                    type: "clipboard.copy",
                    label: "Copy Summary",
                    clipboardText: "Grocery review ready"
                ),
                WorkspaceAppActionSpec(
                    id: "showReminder",
                    type: "notification.show",
                    label: "Show Reminder",
                    notificationTitle: "Review ready",
                    notificationBody: "Open the review queue before shopping."
                ),
                WorkspaceAppActionSpec(
                    id: "exportPipeline",
                    type: "pipeline.run",
                    label: "Export Pipeline",
                    steps: ["listItems", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "bindingPipeline",
                    type: "pipeline.run",
                    label: "Binding Pipeline",
                    steps: ["listItems", "updateItem"]
                ),
                WorkspaceAppActionSpec(
                    id: "awaitPipeline",
                    type: "pipeline.run",
                    label: "Await Pipeline",
                    steps: ["runReviewTask", "updateItem"]
                ),
                WorkspaceAppActionSpec(
                    id: "awaitQueryPipeline",
                    type: "pipeline.run",
                    label: "Await Query Pipeline",
                    steps: ["runReviewTask", "listItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "budgetPipeline",
                    type: "pipeline.run",
                    label: "Budget Pipeline",
                    steps: ["runReviewTask", "agentGate"]
                ),
                WorkspaceAppActionSpec(
                    id: "reduceCount",
                    type: "rows.reduce",
                    label: "Reduce Count",
                    reduceStrategy: "count"
                ),
                WorkspaceAppActionSpec(
                    id: "reducePipeline",
                    type: "pipeline.run",
                    label: "Reduce Pipeline",
                    steps: ["listItems", "reduceCount"]
                ),
                WorkspaceAppActionSpec(
                    id: "branchAction",
                    type: "gate.branch",
                    label: "Branch On Category",
                    gateField: "category",
                    gateOperator: "equals",
                    gateValue: .text("Produce"),
                    steps: ["reduceCount", "listItems"],
                    thenStep: "reduceCount",
                    elseStep: "listItems"
                ),
                WorkspaceAppActionSpec(
                    id: "branchPipeline",
                    type: "pipeline.run",
                    label: "Branch Pipeline",
                    steps: ["listItems", "branchAction"]
                ),
                WorkspaceAppActionSpec(
                    id: "fanOutAction",
                    type: "task.fanOut",
                    label: "Fan Out Review",
                    fanOutStep: "runReviewTask"
                ),
                WorkspaceAppActionSpec(
                    id: "fanOutPipeline",
                    type: "pipeline.run",
                    label: "Fan Out Pipeline",
                    steps: ["listItems", "fanOutAction", "reduceCount"]
                ),
                WorkspaceAppActionSpec(
                    id: "approvalGate",
                    type: "gate.humanApproval",
                    label: "Approve Export",
                    approvalPrompt: "Approve exporting grocery data?",
                    approvalDecisions: ["approve", "reject"]
                ),
                WorkspaceAppActionSpec(
                    id: "approvalPipeline",
                    type: "pipeline.run",
                    label: "Approval Pipeline",
                    steps: ["approvalGate", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "readyGate",
                    type: "gate.expression",
                    label: "Ready Gate",
                    gateField: "status",
                    gateOperator: "equals",
                    gateValue: .text("ready")
                ),
                WorkspaceAppActionSpec(
                    id: "readyPipeline",
                    type: "pipeline.run",
                    label: "Ready Pipeline",
                    steps: ["readyGate", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "agentGate",
                    type: "gate.agentRecommendation",
                    label: "Recommend Export",
                    agentPrompt: "Review the current grocery rows and recommend whether the export should proceed.",
                    agentInputBindings: ["items"],
                    agentDecisions: ["proceed", "hold"],
                    agentPolicyMode: "approvalRequired",
                    agentTokenBudget: 500,
                    agentRequiresApproval: true
                ),
                WorkspaceAppActionSpec(
                    id: "agentPipeline",
                    type: "pipeline.run",
                    label: "Agent Pipeline",
                    steps: ["agentGate", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "boundedLoop",
                    type: "loop.run",
                    label: "Bounded Loop",
                    gateField: "status",
                    gateOperator: "equals",
                    gateValue: .text("done"),
                    steps: ["listItems"],
                    maxIterations: 3,
                    timeoutSeconds: 30,
                    delaySeconds: 0
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                externalWrites: ["recordProject.write"],
                defaultMode: permissionMode
            )
        )
    }
}

private struct MockWorkspaceAppCapabilitySourceClient: WorkspaceAppCapabilitySourceClient {
    var rowsBySourceID: [String: [[String: WorkspaceAppStorageValue]]]

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        rowsBySourceID[source.id] ?? []
    }
}

private struct MockWorkspaceAppCapabilityWriteClient: WorkspaceAppCapabilityWriteClient {
    var result: WorkspaceAppCapabilityWriteResult

    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppCapabilityWriteResult {
        result
    }
}

private final class MockWorkspaceAppUtilityActionClient: WorkspaceAppUtilityActionClient {
    struct Notification: Equatable {
        var title: String
        var body: String
    }

    var openedURLs: [URL] = []
    var clipboardTexts: [String] = []
    var notifications: [Notification] = []

    func openURL(_ url: URL) {
        openedURLs.append(url)
    }

    func copyToClipboard(_ text: String) {
        clipboardTexts.append(text)
    }

    func showNotification(title: String, body: String) {
        notifications.append(Notification(title: title, body: body))
    }
}

private final class MockWorkspaceAppREDCapWriter: WorkspaceAppREDCapWriting {
    var requests: [WorkspaceAppREDCapRequest] = []
    var result: WorkspaceAppCapabilityWriteResult

    init(result: WorkspaceAppCapabilityWriteResult) {
        self.result = result
    }

    func write(_ request: WorkspaceAppREDCapRequest) throws -> WorkspaceAppCapabilityWriteResult {
        requests.append(request)
        return result
    }
}

private final class MockConnectorHTTPTransport: ConnectorHTTPTransport, @unchecked Sendable {
    var lastRequest: URLRequest?
    let body: Data
    let status: Int
    init(body: Data, status: Int) {
        self.body = body
        self.status = status
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://x/")!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}
