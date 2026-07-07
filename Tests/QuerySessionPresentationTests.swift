import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

extension TaskThreadSnapshotTests {
    @Test("Generated file preview finds attached SQL inputs")
    func generatedFilePreviewFindsAttachedSQLInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-attached-sql-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "select 1".write(to: root.appendingPathComponent("query.sql"), atomically: true, encoding: .utf8)
        try "select 2".write(to: nested.appendingPathComponent("report.sql"), atomically: true, encoding: .utf8)
        try "not sql".write(to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskGeneratedFiles.sqlFiles(inInputs: [
            root.appendingPathComponent("query.sql").path,
            root.path,
            root.appendingPathComponent("notes.txt").path
        ])

        #expect(paths.contains(root.appendingPathComponent("query.sql").path))
        #expect(paths.contains(nested.appendingPathComponent("report.sql").path))
        #expect(!paths.contains(nested.appendingPathComponent("notes.txt").path))
    }

    @Test("SQL classifier separates reads from mutations and scripts")
    func sqlClassifierSeparatesReadsFromMutationsAndScripts() {
        #expect(SQLClassifier.classify("-- comment\nselect * from users") == .read)
        #expect(SQLClassifier.classify("with x as (select 1) select * from x") == .read)
        #expect(SQLClassifier.classify("update users set active = false") == .dml)
        #expect(SQLClassifier.classify("create table backup as select * from users") == .ddl)
        #expect(SQLClassifier.classify("select 1; select 2") == .script)
    }

    @Test("AI Brief parser reads prefixed JSON")
    func queryBriefParserReadsPrefixedJSON() throws {
        let output = """
        planning text
        ASTRA_QUERY_BRIEF {"version":1,"goal":"Compare visits","grain":"one row per dataset and visit source","tables":["demo.clinical.visit_occurrence"],"columns":["visit_source_value"],"filters":["visit_source_value LIKE '%History%'"],"joins":[],"assumptions":["History means source value contains History"],"risk":"low","estimatedCost":"12 KB","checks":[{"status":"passed","label":"All referenced columns are listed"}],"notes":["Dry run has not executed"]}
        """

        let brief = try #require(QueryBriefParser.parse(from: output))

        #expect(brief.goal == "Compare visits")
        #expect(brief.grain == "one row per dataset and visit source")
        #expect(brief.risk == .low)
        #expect(brief.checks.first?.status == .passed)
    }

    @Test("Query repair parser reads prefixed JSON")
    func queryRepairParserReadsPrefixedJSON() throws {
        let output = """
        ASTRA_QUERY_REPAIR {"sql":"SELECT 1 AS value","summary":"Replaced the missing column with a constant for validation.","assumptions":["The user only needs a smoke test."]}
        """

        let repair = try #require(QueryRepairParser.parse(from: output))

        #expect(repair.sql == "SELECT 1 AS value")
        #expect(repair.summary.contains("missing column"))
        #expect(repair.assumptions == ["The user only needs a smoke test."])
    }

    @Test("AI result explanation parser reads prefixed JSON")
    func queryResultExplanationParserReadsPrefixedJSON() throws {
        let output = """
        ASTRA_RESULT_EXPLANATION {"version":1,"headline":"stet53 has the dominant History source count.","summary":"The returned preview compares History-like visit sources across two datasets.","keyFindings":["stet53 History has 392224 rows while stet54 History has 1065 rows."],"anomalies":["stet54 is much lower than stet53 for the plain History source."],"caveats":["This only explains the returned preview rows."],"followUps":["Check the upstream source period for stet54."],"checks":[{"status":"warning","label":"Preview rows may be limited by the shelf row limit."}]}
        """

        let explanation = try #require(QueryResultExplanationParser.parse(from: output))

        #expect(explanation.headline.contains("stet53"))
        #expect(explanation.keyFindings.first?.contains("392224") == true)
        #expect(explanation.checks.first?.status == .warning)
    }

    @Test("SQL syntax tokenizer preserves strings comments and quoted identifiers")
    func sqlSyntaxTokenizerPreservesStringsCommentsAndQuotedIdentifiers() {
        let sql = "-- comment\nSELECT 'from' AS source FROM `demo.dataset.table` WHERE value = 42"
        let tokens = SQLSyntaxTokenizer.tokens(in: sql)

        #expect(tokens.contains { $0.kind == .lineComment && $0.text == "-- comment" })
        #expect(tokens.contains { $0.kind == .stringLiteral && $0.text == "'from'" })
        #expect(tokens.contains { $0.kind == .quotedIdentifier && $0.text == "`demo.dataset.table`" })
        #expect(tokens.contains { $0.kind == .number && $0.text == "42" })
    }

    @Test("SQL formatter uppercases keywords and breaks common clauses")
    func sqlFormatterUppercasesKeywordsAndBreaksCommonClauses() {
        let input = """
        -- keep this comment
        select 'from' as source, count(*) as n from `demo.dataset.table` where visit_source_value like '%History%' group by 1 order by n desc
        """

        let formatted = SQLFormatter.format(input)

        #expect(formatted.contains("-- keep this comment"))
        #expect(formatted.contains("SELECT 'from' AS source,"))
        #expect(formatted.contains("\n    COUNT(*) AS n"))
        #expect(formatted.contains("\nFROM `demo.dataset.table`"))
        #expect(formatted.contains("\nWHERE visit_source_value LIKE '%History%'"))
        #expect(formatted.contains("\nGROUP BY 1"))
        #expect(formatted.contains("\nORDER BY n DESC"))
    }

    @MainActor
    @Test("Query session stores generated AI Brief")
    func querySessionStoresGeneratedAIBrief() async throws {
        let session = ShelfQuerySession()
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let expectedBrief = QueryBrief(
            goal: "Preview a constant value",
            grain: "one row",
            tables: [],
            columns: ["value"],
            risk: .low,
            checks: [
                QueryBriefTrustCheck(status: .passed, label: "Read-only SQL")
            ]
        )
        let generator = QueryBriefRecordingGenerator(result: .success(expectedBrief))

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.generateBrief(
            connection: connection,
            taskContext: QueryBriefTaskContext(
                taskTitle: "Check BigQuery",
                taskGoal: "Run a simple query",
                workspaceName: "Analytics"
            ),
            generator: generator
        )

        #expect(session.aiBrief?.goal == "Preview a constant value")
        #expect(session.aiBriefErrorMessage == nil)
        #expect(generator.lastRequest?.sql == "SELECT 1 AS value")
        #expect(generator.lastRequest?.classification == .read)
        #expect(generator.lastRequest?.taskContext?.taskTitle == "Check BigQuery")
    }

    @MainActor
    @Test("Query session clears stale AI Brief when SQL changes")
    func querySessionClearsStaleAIBriefWhenSQLChanges() async {
        let session = ShelfQuerySession()
        let generator = QueryBriefRecordingGenerator(result: .success(QueryBrief(goal: "Initial brief")))

        session.loadSQL("SELECT 1", title: "constant.sql")
        await session.generateBrief(
            connection: .editOnly,
            taskContext: nil,
            generator: generator
        )
        session.updateSelectedSQL("SELECT 2")

        #expect(session.aiBrief == nil)
        #expect(session.aiBriefErrorMessage == nil)
    }

    @MainActor
    @Test("Query session stores generated AI result explanation")
    func querySessionStoresGeneratedAIResultExplanation() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"dataset":"stet53","row_count":392224},{"dataset":"stet54","row_count":1065}]"#,
            stderr: "Total bytes processed: 42"
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let expectedExplanation = QueryResultExplanation(
            headline: "stet53 has many more History rows than stet54.",
            summary: "The preview compares row counts by dataset.",
            keyFindings: ["stet53 has 392224 rows compared with 1065 for stet54."],
            caveats: ["This reflects only the returned preview."]
        )
        let generator = QueryResultExplanationRecordingGenerator(result: .success(expectedExplanation))

        session.loadSQL("SELECT dataset, row_count FROM comparison", title: "comparison.sql")
        await session.run(connection: connection)
        await session.explainResult(
            connection: connection,
            taskContext: QueryBriefTaskContext(
                taskTitle: "Compare History visits",
                taskGoal: "Understand dataset differences",
                workspaceName: "Analytics"
            ),
            generator: generator
        )

        #expect(session.resultExplanation?.headline.contains("stet53") == true)
        #expect(session.resultExplanationErrorMessage == nil)
        #expect(generator.lastRequest?.sql == "SELECT dataset, row_count FROM comparison")
        #expect(generator.lastRequest?.executionResult.rowCount == 2)
        #expect(generator.lastRequest?.taskContext?.taskTitle == "Compare History visits")
    }

    @MainActor
    @Test("Query result explanation requires an executed result")
    func queryResultExplanationRequiresExecutedResult() async {
        let session = ShelfQuerySession()
        let generator = QueryResultExplanationRecordingGenerator(result: .success(QueryResultExplanation(headline: "Unused")))

        session.loadSQL("SELECT 1", title: "constant.sql")
        await session.explainResult(
            connection: .editOnly,
            taskContext: nil,
            generator: generator
        )

        #expect(session.resultExplanation == nil)
        #expect(session.resultExplanationErrorMessage == QueryResultExplanationError.noResult.localizedDescription)
        #expect(generator.lastRequest == nil)
    }

    @MainActor
    @Test("Query session clears stale AI result explanation when SQL changes")
    func querySessionClearsStaleAIResultExplanationWhenSQLChanges() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"value":1}]"#,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let generator = QueryResultExplanationRecordingGenerator(result: .success(QueryResultExplanation(headline: "Initial explanation")))

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.run(connection: connection)
        await session.explainResult(connection: connection, taskContext: nil, generator: generator)
        session.updateSelectedSQL("SELECT 2 AS value")

        #expect(session.resultExplanation == nil)
        #expect(session.resultExplanationErrorMessage == nil)
    }

    @MainActor
    @Test("Self-healing validation passes without repair when dry run succeeds")
    func selfHealingValidationPassesWithoutRepairWhenDryRunSucceeds() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 1 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [])

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: nil,
            repairGenerator: repairGenerator
        )

        #expect(session.sql == "SELECT 1 AS value")
        #expect(session.dryRunResult?.bytesProcessed == 1)
        #expect(session.validationSteps.contains { $0.status == .passed })
        #expect(session.selfHealingOriginalSQL == nil)
        #expect(repairGenerator.requests.isEmpty)
        #expect(await runner.allStandardInputs == ["SELECT 1 AS value"])
    }

    @MainActor
    @Test("Self-healing validation applies AI repair and retries dry run")
    func selfHealingValidationAppliesAIRepairAndRetriesDryRun() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 1), stdout: "", stderr: "Unrecognized name: bad_column"),
            RunResult(
                outcome: .exited(code: 0),
                stdout: "",
                stderr: "Query successfully validated. This query will process 2 bytes when run."
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [
            .success(QueryRepairSuggestion(
                sql: "SELECT 1 AS value",
                summary: "Replaced the missing column with a constant.",
                assumptions: ["The intended smoke test can use a constant value."]
            ))
        ])

        session.loadSQL("SELECT bad_column", title: "broken.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: QueryBriefTaskContext(taskTitle: "Smoke test", taskGoal: "Validate SQL", workspaceName: "Analytics"),
            repairGenerator: repairGenerator
        )

        #expect(session.sql == "SELECT 1 AS value")
        #expect(session.selfHealingOriginalSQL == "SELECT bad_column")
        #expect(session.dryRunResult?.bytesProcessed == 2)
        #expect(repairGenerator.requests.first?.dryRunError.contains("Unrecognized name") == true)
        #expect(session.validationSteps.map(\.status).contains(.failed))
        #expect(session.validationSteps.map(\.status).contains(.repaired))
        #expect(session.validationSteps.map(\.status).contains(.passed))
        #expect(await runner.allStandardInputs == ["SELECT bad_column", "SELECT 1 AS value"])

        session.restoreSelfHealingOriginalSQL()

        #expect(session.sql == "SELECT bad_column")
        #expect(session.selfHealingOriginalSQL == nil)
    }

    @MainActor
    @Test("Self-healing validation blocks mutation SQL before dry run")
    func selfHealingValidationBlocksMutationSQLBeforeDryRun() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [])

        session.loadSQL("DELETE FROM demo.dataset.table WHERE id = 1", title: "delete.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: nil,
            repairGenerator: repairGenerator
        )

        #expect(session.validationErrorMessage?.contains("read-only") == true)
        #expect(session.validationSteps.first?.status == .blocked)
        #expect(repairGenerator.requests.isEmpty)
        #expect((await runner.allArgs).isEmpty)
    }

    @Test("BigQuery dry run parses bytes processed")
    func bigQueryDryRunParsesBytesProcessed() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 12,345 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let result = try await adapter.dryRun(QueryRequest(
            sql: "-- leading comment\nselect 1",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: "demo"
            ),
            rowLimit: 100
        ))

        #expect(result.bytesProcessed == 12345)
        #expect(result.message.contains("12,345 bytes"))
        #expect(await runner.lastStandardInput == "-- leading comment\nselect 1")
        #expect(!((await runner.lastArgs).contains { $0.contains("leading comment") }))
    }

    @Test("BigQuery adapter resolves CLI when operation starts")
    func bigQueryAdapterResolvesCLIWhenOperationStarts() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-bq-lazy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bq = directory.appendingPathComponent("bq")

        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 9 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(
            runner: runner,
            executableResolver: { bq.path }
        )

        try "#!/bin/sh\nexit 0\n".write(to: bq, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bq.path)

        let result = try await adapter.dryRun(QueryRequest(
            sql: "SELECT 1",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: "demo"
            ),
            rowLimit: 100
        ))

        #expect(result.bytesProcessed == 9)
        #expect(await runner.lastPath == bq.path)
        #expect(await runner.lastStandardInput == "SELECT 1")
    }

    @Test("BigQuery missing executable message explains recovery")
    func bigQueryMissingExecutableMessageExplainsRecovery() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-missing-bq-\(UUID().uuidString)")
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: missing.path)

        do {
            _ = try await adapter.dryRun(QueryRequest(
                sql: "SELECT 1",
                connection: DatabaseConnection(
                    id: "bigquery-cli",
                    displayName: "BigQuery",
                    adapterID: "bigquery-cli",
                    dialect: .bigQueryStandard,
                    defaultNamespace: nil,
                    projectID: nil
                ),
                rowLimit: 100
            ))
            Issue.record("Expected missing bq executable to fail")
        } catch {
            #expect(error.localizedDescription.contains("BigQuery CLI"))
            #expect(error.localizedDescription.contains("PATH"))
            #expect(error.localizedDescription.contains("retry"))
        }
    }

    @Test("BigQuery run parses JSON preview rows")
    func bigQueryRunParsesJSONPreviewRows() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"name":"Ada","total":3}]"#,
            stderr: #"totalBytesProcessed: "42""#
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let result = try await adapter.run(QueryRequest(
            sql: "select 'Ada' as name, 3 as total",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: nil
            ),
            rowLimit: 100
        ))

        #expect(Set(result.columns.map(\.name)) == ["name", "total"])
        #expect(Set(result.rows.first ?? []) == ["Ada", "3"])
        #expect(result.bytesProcessed == 42)
    }

    @Test("BigQuery schema lists tables and columns")
    func bigQuerySchemaListsTablesAndColumns() async throws {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"person"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"{"schema":{"fields":[{"name":"person_id","type":"INT64","mode":"REQUIRED"},{"name":"birth_datetime","type":"TIMESTAMP","mode":"NULLABLE"}]}}"#,
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        let catalog = try await adapter.schema(SchemaRequest(connection: connection, datasetID: nil))
        let table = try #require(catalog.datasets.first?.tables.first)
        let detailed = try await adapter.tableSchema(SchemaTableRequest(
            connection: connection,
            projectID: table.projectID,
            datasetID: table.datasetID,
            tableID: table.tableID
        ))

        #expect(table.fullName == "demo:clinical.person")
        #expect(table.projectID == "demo")
        #expect(detailed.columns.map(\.name) == ["person_id", "birth_datetime"])
        #expect(await runner.allArgs == [
            ["--project_id=demo", "ls", "--format=json", "demo:clinical"],
            ["--project_id=demo", "show", "--format=json", "demo:clinical.person"]
        ])
    }

    @Test("BigQuery schema uses datasets referenced by SQL first")
    func bigQuerySchemaUsesDatasetsReferencedBySQLFirst() async throws {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: ""),
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "som-rit-phi-starr-dev"
        )

        _ = try await adapter.schema(SchemaRequest(
            connection: connection,
            datasetID: nil,
            sqlContext: """
            SELECT * FROM `som-rit-phi-starr-dev.stet54_destination.visit_occurrence`
            UNION ALL
            SELECT * FROM `som-rit-phi-starr-dev.stet53_destination.visit_occurrence`
            """
        ))

        #expect(await runner.allArgs == [
            ["--project_id=som-rit-phi-starr-dev", "ls", "--format=json", "som-rit-phi-starr-dev:stet54_destination"],
            ["--project_id=som-rit-phi-starr-dev", "ls", "--format=json", "som-rit-phi-starr-dev:stet53_destination"]
        ])
    }

    @Test("BigQuery schema parser tolerates warning text around JSON")
    func bigQuerySchemaParserToleratesWarningTextAroundJSON() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: """
            Waiting on bq auth refresh...
            [{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"visit_occurrence"},"type":"TABLE"}]
            trailing diagnostic
            """,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let catalog = try await adapter.schema(SchemaRequest(
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: "clinical",
                projectID: "demo"
            ),
            datasetID: nil
        ))

        #expect(catalog.datasets.first?.tables.first?.tableID == "visit_occurrence")
    }

    @Test("BigQuery recovery creates copy backup for mutations")
    func bigQueryRecoveryCreatesCopyBackupForMutations() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let plan = try await adapter.prepareRecovery(QueryRequest(
            sql: "UPDATE `demo.clinical.person` SET active = false WHERE person_id = 1",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: "demo"
            ),
            rowLimit: 100
        ), classification: .dml)

        #expect(plan.isPrepared)
        #expect(plan.sourceTableID == "demo.clinical.person")
        #expect(plan.backupTableID?.contains("demo.clinical.person__astra_backup_") == true)
        #expect(plan.restoreSQL.contains("CREATE OR REPLACE TABLE `demo.clinical.person`"))
        #expect((await runner.lastArgs).prefix(3) == ["--project_id=demo", "cp", "demo:clinical.person"])
    }

    @MainActor
    @Test("Query session blocks mutation after recovery until safety gate is approved")
    func querySessionBlocksMutationAfterRecoveryUntilSafetyGateApproved() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: "", stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        await session.run(connection: connection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(session.safetyGateReview?.isApproved == false)
        #expect(session.errorMessage == "Mutation and script execution is blocked until the safe execution gate is approved.")
        #expect(session.history.first?.status == .blocked)
        #expect((await runner.allArgs).count == 1)
        #expect((await runner.allArgs).first?.contains("cp") == true)
        #expect(await runner.allStandardInputs == [""])
    }

    @MainActor
    @Test("Query session runs mutation after recovery and safety gate approval")
    func querySessionRunsMutationAfterRecoveryAndSafetyGateApproval() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""),
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        session.approveSafetyGate(connection: connection)
        await session.run(connection: connection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(session.hasApprovedSafetyGate(connection: connection))
        #expect(session.errorMessage == nil)
        #expect(session.executionResult?.rowCount == 0)
        #expect(session.history.first?.status == .succeeded)
        #expect(await runner.allStandardInputs.last == "DELETE FROM `demo.clinical.person` WHERE person_id = 1")
    }

    @MainActor
    @Test("Safety gate approval is cleared when SQL changes")
    func safetyGateApprovalIsClearedWhenSQLChanges() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        session.approveSafetyGate(connection: connection)
        session.updateSelectedSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 2")

        #expect(session.recoveryPlan == nil)
        #expect(session.safetyGateReview == nil)
        #expect(!session.hasApprovedSafetyGate(connection: connection))
    }

    @MainActor
    @Test("Safety gate approval cannot reuse recovery from another connection")
    func safetyGateApprovalCannotReuseRecoveryFromAnotherConnection() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let originalConnection = DatabaseConnection(
            id: "bigquery-dev",
            displayName: "BigQuery Dev",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let otherConnection = DatabaseConnection(
            id: "bigquery-prod",
            displayName: "BigQuery Prod",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: originalConnection)
        session.approveSafetyGate(connection: otherConnection)
        await session.run(connection: otherConnection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(!session.hasCurrentPreparedRecovery(connection: otherConnection))
        #expect(!session.hasApprovedSafetyGate(connection: otherConnection))
        #expect(session.errorMessage == "Mutation and script execution is blocked until a prepared recovery plan exists.")
        #expect((await runner.allArgs).count == 1)
        #expect((await runner.allArgs).first?.contains("cp") == true)
    }

    @MainActor
    @Test("Read-only query runs without safety gate approval")
    func readOnlyQueryRunsWithoutSafetyGateApproval() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"value":1}]"#,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )

        session.loadSQL("SELECT 1 AS value", title: "read.sql")
        await session.run(connection: connection)

        #expect(session.safetyGateReview == nil)
        #expect(session.errorMessage == nil)
        #expect(session.executionResult?.rowCount == 1)
        #expect(await runner.allStandardInputs == ["SELECT 1 AS value"])
    }

    @MainActor
    @Test("Query session persists task scoped history")
    func querySessionPersistsTaskScopedHistory() async {
        let taskID = UUID()
        let storageKey = "astra.queryShelf.history.\(taskID.uuidString)"
        UserDefaults.standard.removeObject(forKey: storageKey)
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 1 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )

        session.bindToTask(taskID)
        session.loadSQL("select 1", title: "query.sql")
        await session.dryRun(connection: connection)

        let restored = ShelfQuerySession()
        restored.bindToTask(taskID)

        #expect(restored.history.first?.status == .dryRunSucceeded)
        #expect(restored.history.first?.sql == "select 1")
    }

    @MainActor
    @Test("Query session keeps schema browser when column loading fails")
    func querySessionKeepsSchemaBrowserWhenColumnLoadingFails() async {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"visit_occurrence"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: "not json",
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        await session.loadSchema(connection: connection)
        let table = session.schemaCatalog?.datasets.first?.tables.first
        if let table {
            await session.loadTableSchema(table, connection: connection)
        }

        #expect(session.schemaCatalog?.datasets.first?.tables.first?.tableID == "visit_occurrence")
        #expect(session.schemaErrorMessage == nil)
        #expect(session.tableSchemaErrorTableID == "demo:clinical.visit_occurrence")
        #expect(session.tableSchemaErrorMessage?.contains("without a JSON payload") == true)
    }

    @MainActor
    @Test("Query session loads columns using table project instead of connection project")
    func querySessionLoadsColumnsUsingTableProjectInsteadOfConnectionProject() async {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"som-rit-phi-starr-dev","datasetId":"stet54_destination","tableId":"care_site"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"{"schema":{"fields":[{"name":"care_site_id","type":"INT64"}]}}"#,
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "upo-nero-phi-su-deid-pa"
        )

        session.loadSQL("SELECT * FROM `som-rit-phi-starr-dev.stet54_destination.care_site`", title: "query.sql")
        await session.loadSchema(connection: connection)
        let table = session.schemaCatalog?.datasets.first?.tables.first
        if let table {
            await session.loadTableSchema(table, connection: connection)
        }

        #expect(session.tableSchemaErrorMessage == nil)
        #expect(session.schemaCatalog?.datasets.first?.tables.first?.columns.map(\.name) == ["care_site_id"])
        #expect(await runner.allArgs == [
            [
                "--project_id=upo-nero-phi-su-deid-pa",
                "ls",
                "--format=json",
                "som-rit-phi-starr-dev:stet54_destination"
            ],
            [
                "--project_id=upo-nero-phi-su-deid-pa",
                "show",
                "--format=json",
                "som-rit-phi-starr-dev:stet54_destination.care_site"
            ]
        ])
    }

    @MainActor
    @Test("Query session blocks mutations before execution")
    func querySessionBlocksMutationsBeforeExecution() async {
        let session = ShelfQuerySession()
        session.loadSQL("delete from users where active = false", title: "Dangerous.sql")
        await session.run(connection: DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: nil
        ))

        #expect(session.errorMessage == "Mutation and script execution is blocked until a prepared recovery plan exists.")
        #expect(session.history.first?.status == .blocked)
    }

    @MainActor
    @Test("Query session discovers BigQuery from skill-attached tools")
    func querySessionDiscoversBigQueryFromSkillAttachedTools() {
        let workspace = makeWorkspace(name: "BigQuery")
        let skill = Skill(name: "GCloud Agent")
        skill.workspace = workspace
        let tool = LocalTool(name: "bq - BigQuery CLI", command: "bq", arguments: "")
        tool.workspace = workspace
        tool.skill = skill
        skill.localTools = [tool]
        workspace.skills = [skill]

        let connections = ShelfQuerySession().availableConnections(for: workspace)

        #expect(connections.contains { $0.adapterID == "bigquery-cli" })
    }

    @MainActor
    @Test("Query session discovers BigQuery from enabled global tools")
    func querySessionDiscoversBigQueryFromEnabledGlobalTools() {
        let workspace = makeWorkspace(name: "BigQuery")
        let tool = LocalTool(name: "bq - BigQuery CLI", command: "bq", arguments: "")
        tool.isGlobal = true
        workspace.enabledGlobalToolIDs = [tool.id.uuidString]

        let connections = ShelfQuerySession().availableConnections(
            for: workspace,
            globalTools: [tool]
        )

        #expect(connections.contains { $0.adapterID == "bigquery-cli" })
    }

    @MainActor
    @Test("Query session auto-selects runnable connection when available")
    func querySessionAutoSelectsRunnableConnectionWhenAvailable() {
        let session = ShelfQuerySession()
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery CLI",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: nil
        )

        session.selectConnectionIfNeeded(from: [.editOnly, connection])

        #expect(session.selectedConnectionID == "bigquery-cli")
        #expect(session.selectedDialect == .bigQueryStandard)
    }

    @Test("Generated file preview finds attached Markdown inputs")
    func generatedFilePreviewFindsAttachedMarkdownInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-attached-markdown-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Attached".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "nested".write(to: nested.appendingPathComponent("notes.markdown"), atomically: true, encoding: .utf8)
        try "quarto".write(to: nested.appendingPathComponent("starr_common.qmd"), atomically: true, encoding: .utf8)
        try "html".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskGeneratedFiles.markdownFiles(inInputs: [
            root.appendingPathComponent("README.md").path,
            root.path,
            root.appendingPathComponent("index.html").path
        ])

        #expect(paths.contains(root.appendingPathComponent("README.md").path))
        #expect(paths.contains(nested.appendingPathComponent("notes.markdown").path))
        #expect(paths.contains(nested.appendingPathComponent("starr_common.qmd").path))
        #expect(!paths.contains(root.appendingPathComponent("index.html").path))
    }
}
