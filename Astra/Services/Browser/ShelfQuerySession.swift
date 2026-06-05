import AppKit
import Foundation

struct ShelfQueryDocument: Identifiable, Equatable {
    let id: String
    var title: String
    var sql: String
    var sourcePath: String?
    var isGenerated: Bool
    var savedSQL: String

    var isDirty: Bool { sql != savedSQL }
}

enum QueryValidationStepStatus: String, Equatable, Sendable {
    case running
    case passed
    case failed
    case repaired
    case blocked
}

struct QueryValidationStep: Identifiable, Equatable, Sendable {
    var id: String { "\(status.rawValue)-\(title)-\(detail)" }
    var status: QueryValidationStepStatus
    var title: String
    var detail: String
}

enum QuerySafetyGateCheckStatus: String, Equatable, Sendable {
    case passed
    case warning
    case blocked
}

struct QuerySafetyGateCheck: Identifiable, Equatable, Sendable {
    var id: String { "\(status.rawValue)-\(label)" }
    var status: QuerySafetyGateCheckStatus
    var label: String
}

struct QuerySafetyGateReview: Equatable, Sendable {
    var signature: String
    var connectionName: String
    var dialect: SQLDialect
    var classification: QueryClassification
    var recoveryTitle: String
    var recoveryDetails: String
    var restoreSQL: String
    var sourceTableID: String?
    var backupTableID: String?
    var checks: [QuerySafetyGateCheck]
    var approvedAt: Date?

    var isApproved: Bool {
        approvedAt != nil
    }
}

@MainActor
final class ShelfQuerySession: ObservableObject {
    @Published private(set) var documents: [ShelfQueryDocument] = []
    @Published private(set) var selectedDocumentID: String?
    @Published private(set) var boundTaskID: UUID?
    @Published var selectedConnectionID = DatabaseConnection.editOnly.id
    @Published var selectedDialect: SQLDialect = .bigQueryStandard
    @Published var rowLimit = 100
    @Published private(set) var history: [QueryHistoryEntry] = []
    @Published private(set) var dryRunResult: QueryDryRunResult?
    @Published private(set) var executionResult: QueryExecutionResult?
    @Published private(set) var recoveryPlan: RecoveryPlan?
    @Published private(set) var aiBrief: QueryBrief?
    @Published private(set) var aiBriefErrorMessage: String?
    @Published private(set) var resultExplanation: QueryResultExplanation?
    @Published private(set) var resultExplanationErrorMessage: String?
    @Published private(set) var validationSteps: [QueryValidationStep] = []
    @Published private(set) var validationErrorMessage: String?
    @Published private(set) var selfHealingOriginalSQL: String?
    @Published private(set) var safetyGateReview: QuerySafetyGateReview?
    @Published private(set) var schemaCatalog: SchemaCatalog?
    @Published private(set) var schemaErrorMessage: String?
    @Published private(set) var tableSchemaErrorMessage: String?
    @Published private(set) var tableSchemaErrorTableID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingSchema = false
    @Published private(set) var isGeneratingBrief = false
    @Published private(set) var isExplainingResult = false
    @Published private(set) var isValidatingQuery = false

    private let queryService: DatabaseQueryService

    init(queryService: DatabaseQueryService = DatabaseQueryService()) {
        self.queryService = queryService
        newScratchQuery()
    }

    var selectedDocument: ShelfQueryDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var sql: String {
        selectedDocument?.sql ?? ""
    }

    var title: String {
        selectedDocument?.title ?? "Query"
    }

    var displayPath: String {
        selectedDocument?.sourcePath ?? ""
    }

    var hasQuery: Bool {
        selectedDocument != nil
    }

    var classification: QueryClassification {
        SQLClassifier.classify(sql)
    }

    var requiresPreparedRecovery: Bool {
        classification.requiresRecovery
    }

    var hasPreparedRecovery: Bool {
        recoveryPlan?.isPrepared == true
    }

    var requiresSafetyGate: Bool {
        classification.requiresRecovery
    }

    var canSaveSelectedDocument: Bool {
        selectedDocument?.sourcePath != nil
    }

    var canRestoreSelfHealingOriginalSQL: Bool {
        selfHealingOriginalSQL != nil
    }

    func bindToTask(_ taskID: UUID?) {
        boundTaskID = taskID
        loadPersistedHistory()
    }

    func selectDocument(_ id: String) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedDocumentID = id
        resetResults()
    }

    func newScratchQuery(sql: String = "", title: String = "Untitled Query") {
        let document = ShelfQueryDocument(
            id: UUID().uuidString,
            title: title,
            sql: sql,
            sourcePath: nil,
            isGenerated: false,
            savedSQL: sql
        )
        documents.append(document)
        selectedDocumentID = document.id
        resetResults()
    }

    func loadFile(_ url: URL) {
        let sql = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let document = ShelfQueryDocument(
            id: url.path,
            title: url.lastPathComponent,
            sql: sql,
            sourcePath: url.path,
            isGenerated: false,
            savedSQL: sql
        )
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
        selectedDocumentID = document.id
        resetResults()
    }

    func loadSQL(_ sql: String, title: String, generated: Bool = true) {
        let document = ShelfQueryDocument(
            id: UUID().uuidString,
            title: title,
            sql: sql,
            sourcePath: nil,
            isGenerated: generated,
            savedSQL: sql
        )
        documents.append(document)
        selectedDocumentID = document.id
        resetResults()
    }

    func updateSelectedSQL(_ sql: String) {
        setSelectedSQL(sql, resetState: true)
    }

    private func setSelectedSQL(_ sql: String, resetState: Bool) {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else {
            return
        }
        let previousSQL = documents[index].sql
        documents[index].sql = sql
        if previousSQL != sql, resetState {
            resetResults()
        }
    }

    func saveSelectedDocument() {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }),
              let path = documents[index].sourcePath else {
            return
        }
        do {
            try documents[index].sql.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            documents[index].savedSQL = documents[index].sql
            errorMessage = nil
        } catch {
            errorMessage = "Could not save \(documents[index].title): \(error.localizedDescription)"
        }
    }

    func closeDocument(_ id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedDocumentID == id
        documents.remove(at: index)
        if documents.isEmpty {
            newScratchQuery()
            return
        }
        if wasSelected {
            selectedDocumentID = documents[min(index, documents.count - 1)].id
            resetResults()
        }
    }

    func copySQLToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    func availableConnections(
        for workspace: Workspace?,
        globalConnectors: [Connector] = [],
        globalTools: [LocalTool] = []
    ) -> [DatabaseConnection] {
        var connections = [DatabaseConnection.editOnly]
        guard let workspace else { return connections }
        let connectors = activeConnectors(
            for: workspace,
            globalConnectors: globalConnectors
        )
        let tools = activeTools(
            for: workspace,
            globalTools: globalTools
        )
        let config = connectors
            .first { isBigQueryConnector($0) }?
            .config ?? [:]
        let projectID = config["GCP_PROJECT"] ?? config["PROJECT_ID"]
        let namespace = config["BQ_DATASET"] ?? config["DATASET"] ?? config["GCP_DATASET"]

        if workspace.enabledCapabilityIDs.contains("gcloud-workflow") ||
            workspace.installedPluginIDSet.contains("gcloud-workflow") ||
            connectors.contains(where: isBigQueryConnector) ||
            tools.contains(where: isBigQueryTool) {
            connections.append(DatabaseConnection(
                id: "bigquery-cli",
                displayName: projectID.map { "BigQuery - \($0)" } ?? "BigQuery CLI",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: namespace,
                projectID: projectID
            ))
        }
        return connections
    }

    private func activeConnectors(
        for workspace: Workspace,
        globalConnectors: [Connector]
    ) -> [Connector] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalConnectorIDs)
        return uniqueConnectors(
            workspace.connectors +
            workspace.skills.flatMap(\.connectors) +
            globalConnectors.filter { enabledGlobalIDs.contains($0.id.uuidString) }
        )
    }

    private func activeTools(
        for workspace: Workspace,
        globalTools: [LocalTool]
    ) -> [LocalTool] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalToolIDs)
        return uniqueTools(
            workspace.localTools +
            workspace.skills.flatMap(\.localTools) +
            globalTools.filter { enabledGlobalIDs.contains($0.id.uuidString) }
        )
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors.filter { seen.insert($0.id).inserted }
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return tools.filter { seen.insert($0.id).inserted }
    }

    private func isBigQueryConnector(_ connector: Connector) -> Bool {
        let serviceType = connector.serviceType.lowercased()
        return serviceType == "gcloud" || serviceType == "bigquery" || serviceType == "database"
    }

    private func isBigQueryTool(_ tool: LocalTool) -> Bool {
        tool.command == "bq" || tool.displayCommand.split(separator: " ").contains("bq")
    }

    func selectedConnection(in connections: [DatabaseConnection]) -> DatabaseConnection {
        connections.first { $0.id == selectedConnectionID } ?? connections.first ?? .editOnly
    }

    func selectConnectionIfNeeded(from connections: [DatabaseConnection]) {
        if selectedConnectionID == DatabaseConnection.editOnly.id,
           let runnableConnection = connections.first(where: { $0.id != DatabaseConnection.editOnly.id }) {
            selectedConnectionID = runnableConnection.id
            selectedDialect = runnableConnection.dialect
            return
        }
        guard !connections.contains(where: { $0.id == selectedConnectionID }) else { return }
        selectedConnectionID = connections.first?.id ?? DatabaseConnection.editOnly.id
    }

    func dryRun(connection: DatabaseConnection) async {
        let connection = requestConnection(from: connection)
        let request = QueryRequest(sql: sql, connection: connection, rowLimit: rowLimit)
        isRunning = true
        errorMessage = nil
        dryRunResult = nil
        defer { isRunning = false }
        do {
            let result = try await queryService.dryRun(request)
            dryRunResult = result
            appendHistory(status: .dryRunSucceeded, connection: connection, dryRun: result)
        } catch {
            errorMessage = error.localizedDescription
            appendHistory(status: .failed, connection: connection, errorMessage: error.localizedDescription)
        }
    }

    func run(connection: DatabaseConnection) async {
        let connection = requestConnection(from: connection)
        let currentClassification = classification
        guard !currentClassification.requiresRecovery || hasCurrentPreparedRecovery(connection: connection) else {
            let message = "Mutation and script execution is blocked until a prepared recovery plan exists."
            errorMessage = message
            appendHistory(status: .blocked, connection: connection, errorMessage: message)
            return
        }
        guard !currentClassification.requiresRecovery || hasApprovedSafetyGate(connection: connection) else {
            let message = "Mutation and script execution is blocked until the safe execution gate is approved."
            errorMessage = message
            appendHistory(status: .blocked, connection: connection, errorMessage: message)
            return
        }

        let request = QueryRequest(sql: sql, connection: connection, rowLimit: rowLimit)
        isRunning = true
        errorMessage = nil
        executionResult = nil
        resultExplanation = nil
        resultExplanationErrorMessage = nil
        defer { isRunning = false }
        do {
            let result = try await queryService.run(request)
            executionResult = result
            appendHistory(status: .succeeded, connection: connection, result: result)
        } catch {
            errorMessage = error.localizedDescription
            appendHistory(status: .failed, connection: connection, errorMessage: error.localizedDescription)
        }
    }

    func loadSchema(connection: DatabaseConnection) async {
        let connection = requestConnection(from: connection)
        isLoadingSchema = true
        schemaErrorMessage = nil
        tableSchemaErrorMessage = nil
        tableSchemaErrorTableID = nil
        defer { isLoadingSchema = false }
        do {
            schemaCatalog = try await queryService.schema(SchemaRequest(
                connection: connection,
                datasetID: nil,
                sqlContext: sql
            ))
            AppLogger.info(
                "Query shelf schema loaded connection=\(connection.displayName) datasets=\(schemaCatalog?.datasets.count ?? 0)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        } catch {
            schemaErrorMessage = error.localizedDescription
            AppLogger.error(
                "Query shelf schema failed connection=\(connection.displayName) error=\(error.localizedDescription)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        }
    }

    func loadTableSchema(_ table: SchemaTable, connection: DatabaseConnection) async {
        let connection = requestConnection(from: connection)
        isLoadingSchema = true
        tableSchemaErrorMessage = nil
        tableSchemaErrorTableID = nil
        defer { isLoadingSchema = false }
        do {
            let fullTable = try await queryService.tableSchema(SchemaTableRequest(
                connection: connection,
                projectID: table.projectID,
                datasetID: table.datasetID,
                tableID: table.tableID
            ))
            upsertTableSchema(fullTable)
            AppLogger.info(
                "Query shelf columns loaded table=\(table.fullName) columns=\(fullTable.columns.count)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        } catch {
            tableSchemaErrorTableID = table.id
            tableSchemaErrorMessage = error.localizedDescription
            AppLogger.error(
                "Query shelf columns failed table=\(table.fullName) connection=\(connection.displayName) error=\(error.localizedDescription)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        }
    }

    func insertTableName(_ table: SchemaTable) {
        appendSQLFragment("`\(table.fullName.replacingOccurrences(of: ":", with: "."))`")
    }

    func insertColumns(_ columns: [SchemaColumn]) {
        guard !columns.isEmpty else { return }
        appendSQLFragment(columns.map(\.name).joined(separator: ", "))
    }

    func prepareRecovery(connection: DatabaseConnection) async {
        let connection = requestConnection(from: connection)
        let request = QueryRequest(sql: sql, connection: connection, rowLimit: rowLimit)
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let plan = try await queryService.prepareRecovery(request, classification: classification)
            recoveryPlan = plan
            safetyGateReview = plan.isPrepared && classification.requiresRecovery
                ? makeSafetyGateReview(connection: connection, recoveryPlan: plan, approvedAt: nil)
                : nil
            appendHistory(status: .blocked, connection: connection, recoveryPlan: plan)
        } catch {
            errorMessage = error.localizedDescription
            appendHistory(status: .failed, connection: connection, errorMessage: error.localizedDescription)
        }
    }

    func hasApprovedSafetyGate(connection: DatabaseConnection) -> Bool {
        guard let safetyGateReview,
              safetyGateReview.isApproved,
              safetyGateReview.signature == safetyGateSignature(connection: requestConnection(from: connection)),
              hasCurrentPreparedRecovery(connection: connection) else {
            return false
        }
        return true
    }

    func hasCurrentPreparedRecovery(connection: DatabaseConnection) -> Bool {
        guard recoveryPlan?.isPrepared == true else {
            return false
        }
        guard classification.requiresRecovery else {
            return true
        }
        return safetyGateReview?.signature == safetyGateSignature(connection: requestConnection(from: connection))
    }

    func approveSafetyGate(connection: DatabaseConnection) {
        let connection = requestConnection(from: connection)
        guard classification.requiresRecovery else {
            safetyGateReview = nil
            return
        }
        guard let recoveryPlan, recoveryPlan.isPrepared else {
            let message = "Prepare recovery before approving the safe execution gate."
            errorMessage = message
            safetyGateReview = makeBlockedSafetyGateReview(connection: connection, message: message)
            return
        }
        guard safetyGateReview?.signature == safetyGateSignature(connection: connection) else {
            let message = "Prepare recovery again before approving this SQL, dialect, and connection."
            errorMessage = message
            return
        }
        safetyGateReview = makeSafetyGateReview(
            connection: connection,
            recoveryPlan: recoveryPlan,
            approvedAt: Date()
        )
        errorMessage = nil
        AppLogger.info(
            "Query shelf safe execution gate approved classification=\(classification.rawValue)",
            category: "QueryShelf",
            taskID: boundTaskID
        )
    }

    func validateAndRepair(
        connection: DatabaseConnection,
        taskContext: QueryBriefTaskContext?,
        repairGenerator: QueryRepairGenerating,
        maxRepairAttempts: Int = 2
    ) async {
        let originalSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalSQL.isEmpty else {
            validationSteps = [
                QueryValidationStep(status: .blocked, title: "No SQL", detail: "Write or open SQL before validating.")
            ]
            validationErrorMessage = "Write or open SQL before validating."
            return
        }

        guard connection.id != DatabaseConnection.editOnly.id else {
            let message = "Choose a database connection before validating SQL."
            validationSteps = [
                QueryValidationStep(status: .blocked, title: "No connection", detail: message)
            ]
            validationErrorMessage = message
            errorMessage = message
            return
        }

        let originalClassification = SQLClassifier.classify(originalSQL)
        guard originalClassification == .read else {
            let message = "Self-healing dry-run validation only runs automatically for read-only SQL."
            validationSteps = [
                QueryValidationStep(status: .blocked, title: "Blocked", detail: message)
            ]
            validationErrorMessage = message
            errorMessage = message
            return
        }

        let connection = requestConnection(from: connection)
        validationSteps = [
            QueryValidationStep(status: .running, title: "Started", detail: "Running an automatic dry run.")
        ]
        validationErrorMessage = nil
        errorMessage = nil
        dryRunResult = nil
        executionResult = nil
        resultExplanation = nil
        resultExplanationErrorMessage = nil
        recoveryPlan = nil
        selfHealingOriginalSQL = nil
        isRunning = true
        isValidatingQuery = true
        defer {
            isRunning = false
            isValidatingQuery = false
        }

        var candidateSQL = originalSQL
        var repairAttempt = 0

        while true {
            let dryRunAttempt = repairAttempt + 1
            appendValidationStep(.running, title: "Dry run \(dryRunAttempt)", detail: "Checking SQL syntax and cost without execution.")

            do {
                let result = try await queryService.dryRun(QueryRequest(
                    sql: candidateSQL,
                    connection: connection,
                    rowLimit: rowLimit
                ))
                dryRunResult = result
                errorMessage = nil
                appendValidationStep(.passed, title: "Dry run passed", detail: dryRunPassedDetail(result))
                appendHistory(status: .dryRunSucceeded, connection: connection, dryRun: result)
                AppLogger.info(
                    "Query shelf self-healing validation passed repairs=\(repairAttempt)",
                    category: "QueryShelf",
                    taskID: boundTaskID
                )
                return
            } catch {
                let dryRunError = error.localizedDescription
                appendValidationStep(.failed, title: "Dry run failed", detail: dryRunError)

                guard repairAttempt < maxRepairAttempts else {
                    validationErrorMessage = dryRunError
                    errorMessage = dryRunError
                    appendHistory(status: .failed, connection: connection, errorMessage: dryRunError)
                    AppLogger.error(
                        "Query shelf self-healing validation failed repairs=\(repairAttempt) error=\(dryRunError)",
                        category: "QueryShelf",
                        taskID: boundTaskID
                    )
                    return
                }

                repairAttempt += 1
                appendValidationStep(.running, title: "Repair \(repairAttempt)", detail: "Asking AI for a minimal read-only SQL repair.")

                do {
                    let repair = try await repairGenerator.repair(QueryRepairRequest(
                        title: title,
                        originalSQL: originalSQL,
                        failedSQL: candidateSQL,
                        dryRunError: dryRunError,
                        attempt: repairAttempt,
                        connection: connection,
                        dialect: selectedDialect,
                        schemaCatalog: schemaCatalog,
                        taskContext: taskContext
                    ))
                    let repairedSQL = repair.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !repairedSQL.isEmpty else {
                        throw QueryRepairGenerationError.invalidOutput("The repaired SQL was empty.")
                    }
                    guard SQLClassifier.classify(repairedSQL) == .read else {
                        throw QueryRepairGenerationError.unsafeSQL("AI repair returned non-read-only SQL, so ASTRA did not apply it.")
                    }
                    guard repairedSQL != candidateSQL else {
                        throw QueryRepairGenerationError.invalidOutput("AI returned the same SQL after a failed dry run.")
                    }

                    if selfHealingOriginalSQL == nil {
                        selfHealingOriginalSQL = originalSQL
                    }
                    candidateSQL = repairedSQL
                    setSelectedSQL(repairedSQL, resetState: false)
                    dryRunResult = nil
                    errorMessage = nil
                    aiBrief = nil
                    aiBriefErrorMessage = nil
                    resultExplanation = nil
                    resultExplanationErrorMessage = nil

                    let assumptions = repair.assumptions.isEmpty
                        ? ""
                        : " Assumptions: \(repair.assumptions.joined(separator: "; "))"
                    appendValidationStep(.repaired, title: "SQL repaired", detail: "\(repair.summary)\(assumptions)")
                } catch {
                    let message = error.localizedDescription
                    validationErrorMessage = message
                    errorMessage = message
                    appendValidationStep(.blocked, title: "Repair stopped", detail: message)
                    appendHistory(status: .failed, connection: connection, errorMessage: message)
                    AppLogger.error(
                        "Query shelf self-healing repair failed attempt=\(repairAttempt) error=\(message)",
                        category: "QueryShelf",
                        taskID: boundTaskID
                    )
                    return
                }
            }
        }
    }

    func restoreSelfHealingOriginalSQL() {
        guard let original = selfHealingOriginalSQL else { return }
        setSelectedSQL(original, resetState: false)
        dryRunResult = nil
        executionResult = nil
        recoveryPlan = nil
        aiBrief = nil
        aiBriefErrorMessage = nil
        resultExplanation = nil
        resultExplanationErrorMessage = nil
        errorMessage = nil
        validationErrorMessage = nil
        validationSteps = [
            QueryValidationStep(status: .repaired, title: "Original restored", detail: "Restored the SQL from before AI repair.")
        ]
        selfHealingOriginalSQL = nil
    }

    func generateBrief(
        connection: DatabaseConnection,
        taskContext: QueryBriefTaskContext?,
        generator: QueryBriefGenerating
    ) async {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSQL.isEmpty else {
            aiBrief = nil
            aiBriefErrorMessage = QueryBriefGenerationError.emptySQL.localizedDescription
            return
        }

        let connection = requestConnection(from: connection)
        let request = QueryBriefRequest(
            title: title,
            sql: trimmedSQL,
            connection: connection,
            dialect: selectedDialect,
            classification: classification,
            rowLimit: rowLimit,
            dryRunResult: dryRunResult,
            schemaCatalog: schemaCatalog,
            taskContext: taskContext
        )

        isGeneratingBrief = true
        aiBriefErrorMessage = nil
        defer { isGeneratingBrief = false }

        do {
            let brief = try await generator.generateBrief(request)
            aiBrief = brief
            AppLogger.info(
                "Query shelf AI Brief generated title=\(title) risk=\(brief.risk.rawValue)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        } catch {
            aiBrief = nil
            aiBriefErrorMessage = error.localizedDescription
            AppLogger.error(
                "Query shelf AI Brief failed title=\(title) error=\(error.localizedDescription)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        }
    }

    func explainResult(
        connection: DatabaseConnection,
        taskContext: QueryBriefTaskContext?,
        generator: QueryResultExplanationGenerating
    ) async {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSQL.isEmpty else {
            resultExplanation = nil
            resultExplanationErrorMessage = QueryResultExplanationError.emptySQL.localizedDescription
            return
        }
        guard let executionResult else {
            resultExplanation = nil
            resultExplanationErrorMessage = QueryResultExplanationError.noResult.localizedDescription
            return
        }

        let connection = requestConnection(from: connection)
        let request = QueryResultExplanationRequest(
            title: title,
            sql: trimmedSQL,
            connection: connection,
            dialect: selectedDialect,
            rowLimit: rowLimit,
            dryRunResult: dryRunResult,
            executionResult: executionResult,
            schemaCatalog: schemaCatalog,
            taskContext: taskContext,
            brief: aiBrief
        )

        isExplainingResult = true
        resultExplanationErrorMessage = nil
        defer { isExplainingResult = false }

        do {
            let explanation = try await generator.explainResult(request)
            resultExplanation = explanation
            AppLogger.info(
                "Query shelf result explanation generated title=\(title) rows=\(executionResult.rowCount)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        } catch {
            resultExplanation = nil
            resultExplanationErrorMessage = error.localizedDescription
            AppLogger.error(
                "Query shelf result explanation failed title=\(title) error=\(error.localizedDescription)",
                category: "QueryShelf",
                taskID: boundTaskID
            )
        }
    }

    private func upsertTableSchema(_ table: SchemaTable) {
        guard var catalog = schemaCatalog,
              let datasetIndex = catalog.datasets.firstIndex(where: { $0.datasetID == table.datasetID }) else {
            schemaCatalog = SchemaCatalog(datasets: [
                SchemaDataset(datasetID: table.datasetID, displayName: table.datasetID, tables: [table])
            ])
            return
        }
        if let tableIndex = catalog.datasets[datasetIndex].tables.firstIndex(where: { $0.tableID == table.tableID }) {
            catalog.datasets[datasetIndex].tables[tableIndex] = table
        } else {
            catalog.datasets[datasetIndex].tables.append(table)
        }
        schemaCatalog = catalog
    }

    private func appendSQLFragment(_ fragment: String) {
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else {
            return
        }
        let separator = documents[index].sql.hasSuffix(" ") || documents[index].sql.hasSuffix("\n") ? "" : " "
        documents[index].sql += "\(separator)\(fragment)"
        resetResults()
    }

    private func appendHistory(
        status: QueryExecutionStatus,
        connection: DatabaseConnection,
        dryRun: QueryDryRunResult? = nil,
        result: QueryExecutionResult? = nil,
        recoveryPlan: RecoveryPlan? = nil,
        errorMessage: String? = nil
    ) {
        history.insert(QueryHistoryEntry(
            sql: sql,
            connectionName: connection.displayName,
            dialect: connection.dialect,
            classification: classification,
            status: status,
            dryRun: dryRun,
            result: result,
            recoveryPlan: recoveryPlan,
            errorMessage: errorMessage
        ), at: 0)
        if history.count > 50 {
            history.removeLast(history.count - 50)
        }
        persistHistory()
    }

    private func makeSafetyGateReview(
        connection: DatabaseConnection,
        recoveryPlan: RecoveryPlan,
        approvedAt: Date?
    ) -> QuerySafetyGateReview {
        QuerySafetyGateReview(
            signature: safetyGateSignature(connection: connection),
            connectionName: connection.displayName,
            dialect: selectedDialect,
            classification: classification,
            recoveryTitle: recoveryPlan.title,
            recoveryDetails: recoveryPlan.details,
            restoreSQL: recoveryPlan.restoreSQL,
            sourceTableID: recoveryPlan.sourceTableID,
            backupTableID: recoveryPlan.backupTableID,
            checks: safetyGateChecks(recoveryPlan: recoveryPlan),
            approvedAt: approvedAt
        )
    }

    private func makeBlockedSafetyGateReview(connection: DatabaseConnection, message: String) -> QuerySafetyGateReview {
        QuerySafetyGateReview(
            signature: safetyGateSignature(connection: connection),
            connectionName: connection.displayName,
            dialect: selectedDialect,
            classification: classification,
            recoveryTitle: "Recovery not prepared",
            recoveryDetails: message,
            restoreSQL: "",
            sourceTableID: nil,
            backupTableID: nil,
            checks: [
                QuerySafetyGateCheck(status: .blocked, label: message)
            ],
            approvedAt: nil
        )
    }

    private func safetyGateChecks(recoveryPlan: RecoveryPlan) -> [QuerySafetyGateCheck] {
        var checks = [
            QuerySafetyGateCheck(
                status: .warning,
                label: "\(classification.displayName) requires explicit approval before execution."
            ),
            QuerySafetyGateCheck(
                status: recoveryPlan.isPrepared ? .passed : .blocked,
                label: recoveryPlan.isPrepared ? "Recovery is prepared." : "Recovery is not prepared."
            )
        ]

        if let source = recoveryPlan.sourceTableID, !source.isEmpty {
            checks.append(QuerySafetyGateCheck(status: .warning, label: "Affected object: \(source)"))
        }
        if let backup = recoveryPlan.backupTableID, !backup.isEmpty {
            checks.append(QuerySafetyGateCheck(status: .passed, label: "Backup object: \(backup)"))
        }
        checks.append(QuerySafetyGateCheck(
            status: recoveryPlan.restoreSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .warning : .passed,
            label: recoveryPlan.restoreSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No restore SQL was recorded."
                : "Restore SQL is recorded."
        ))
        return checks
    }

    private func safetyGateSignature(connection: DatabaseConnection) -> String {
        [
            connection.id,
            selectedDialect.rawValue,
            classification.rawValue,
            sql.trimmingCharacters(in: .whitespacesAndNewlines),
            recoveryPlan?.title ?? "",
            recoveryPlan?.restoreSQL ?? "",
            recoveryPlan?.sourceTableID ?? "",
            recoveryPlan?.backupTableID ?? ""
        ].joined(separator: "\u{1F}")
    }

    private func appendValidationStep(_ status: QueryValidationStepStatus, title: String, detail: String) {
        validationSteps.append(QueryValidationStep(status: status, title: title, detail: detail))
    }

    private func dryRunPassedDetail(_ result: QueryDryRunResult) -> String {
        if let bytes = result.bytesProcessed {
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) estimated. \(result.message)"
        }
        return result.message
    }

    private func requestConnection(from connection: DatabaseConnection) -> DatabaseConnection {
        var requestConnection = connection
        requestConnection.dialect = selectedDialect
        return requestConnection
    }

    private func resetResults() {
        dryRunResult = nil
        executionResult = nil
        recoveryPlan = nil
        errorMessage = nil
        aiBrief = nil
        aiBriefErrorMessage = nil
        resultExplanation = nil
        resultExplanationErrorMessage = nil
        validationSteps = []
        validationErrorMessage = nil
        selfHealingOriginalSQL = nil
        safetyGateReview = nil
    }

    private func loadPersistedHistory() {
        guard let key = historyStorageKey else {
            history = []
            return
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) else {
            history = []
            return
        }
        history = Array(entries.prefix(50))
    }

    private func persistHistory() {
        guard let key = historyStorageKey,
              let data = try? JSONEncoder().encode(history) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private var historyStorageKey: String? {
        guard let boundTaskID else { return nil }
        return "astra.queryShelf.history.\(boundTaskID.uuidString)"
    }
}
