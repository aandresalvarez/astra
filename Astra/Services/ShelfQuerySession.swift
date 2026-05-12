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
    @Published private(set) var schemaCatalog: SchemaCatalog?
    @Published private(set) var schemaErrorMessage: String?
    @Published private(set) var tableSchemaErrorMessage: String?
    @Published private(set) var tableSchemaErrorTableID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isLoadingSchema = false

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

    var canSaveSelectedDocument: Bool {
        selectedDocument?.sourcePath != nil
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
        guard let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else {
            return
        }
        let previousSQL = documents[index].sql
        documents[index].sql = sql
        if previousSQL != sql {
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
        let currentClassification = classification
        guard !currentClassification.requiresRecovery || hasPreparedRecovery else {
            let message = "Mutation and script execution is blocked until a prepared recovery plan exists."
            errorMessage = message
            appendHistory(status: .blocked, connection: connection, errorMessage: message)
            return
        }

        let connection = requestConnection(from: connection)
        let request = QueryRequest(sql: sql, connection: connection, rowLimit: rowLimit)
        isRunning = true
        errorMessage = nil
        executionResult = nil
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
            appendHistory(status: .blocked, connection: connection, recoveryPlan: plan)
        } catch {
            errorMessage = error.localizedDescription
            appendHistory(status: .failed, connection: connection, errorMessage: error.localizedDescription)
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
