import SwiftUI
import SwiftData

struct ShelfQueryPanelView: View {
    @ObservedObject var session: ShelfQuerySession
    let workspace: Workspace?
    @Binding var isPresented: Bool
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true }) private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true }) private var globalTools: [LocalTool]

    @State private var selectedTab: QueryShelfTab = .results
    @State private var selectedSchemaTableID: String?

    private var connections: [DatabaseConnection] {
        session.availableConnections(
            for: workspace,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var selectedConnection: DatabaseConnection {
        session.selectedConnection(in: connections)
    }

    private var hasRunnableSQL: Bool {
        !session.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !session.documents.isEmpty {
                tabStrip
            }
            Divider()
            safetyStrip
            Divider()
            queryEditor
                .frame(minHeight: 180)
            Divider()
            resultTabs
            Divider()
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(ObjectIdentifier(session))
        .onAppear(perform: normalizeConnection)
        .onChange(of: workspace?.id) {
            normalizeConnection()
        }
        .onChange(of: session.selectedConnectionID) {
            syncDialectWithSelectedConnection()
            if selectedTab == .schema {
                loadSchema(force: true)
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab == .schema {
                loadSchema(force: false)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !session.displayPath.isEmpty {
                    Text(session.displayPath)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Picker("", selection: $session.selectedConnectionID) {
                ForEach(connections) { connection in
                    Text(connection.displayName).tag(connection.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 190)
            .help("Database connection")

            Picker("", selection: $session.selectedDialect) {
                ForEach(SQLDialect.allCases.filter { $0 != .unknown }) { dialect in
                    Text(dialect.displayName).tag(dialect)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 170)
            .help("SQL dialect")

            Button {
                session.newScratchQuery(sql: "-- Write SQL here\n", title: "Untitled Query")
            } label: {
                Image(systemName: "plus")
            }
            .help("New query")

            Button {
                session.saveSelectedDocument()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!session.canSaveSelectedDocument)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save SQL file")

            Button {
                session.copySQLToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(!hasRunnableSQL)
            .help("Copy SQL")

            Button {
                Task { await session.dryRun(connection: selectedConnection) }
            } label: {
                Image(systemName: "checkmark.seal")
            }
            .disabled(!canExecute)
            .help("Dry run query")

            Button {
                Task { await session.run(connection: selectedConnection) }
            } label: {
                if session.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .disabled(!canRun)
            .help(runHelp)

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close query shelf")
        }
        .buttonStyle(QueryShelfToolbarButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.documents) { document in
                    queryTab(document)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .frame(height: 40)
        .background(Stanford.cardBackground.opacity(0.55))
    }

    private func queryTab(_ document: ShelfQueryDocument) -> some View {
        let isSelected = session.selectedDocumentID == document.id
        return HStack(spacing: 6) {
            Button {
                session.selectDocument(document.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(Stanford.ui(11, weight: .semibold))
                    Text(document.title)
                        .font(Stanford.ui(12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if document.isDirty {
                        Circle()
                            .fill(Stanford.cardinalRed)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                .foregroundStyle(isSelected ? Stanford.black : Stanford.coolGrey)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.sourcePath ?? document.title)

            Button {
                session.closeDocument(document.id)
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.black.opacity(0.75) : Stanford.coolGrey.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.001)))
            }
            .buttonStyle(.plain)
            .help("Close \(document.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 34)
        .background(isSelected ? Stanford.cardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Stanford.lagunita : Color.clear)
                .frame(height: 2)
        }
    }

    private var safetyStrip: some View {
        HStack(spacing: 10) {
            Label(session.classification.displayName, systemImage: classificationIcon)
                .foregroundStyle(classificationColor)
                .font(Stanford.ui(12, weight: .semibold))

            Text(safetyMessage)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            TextField("Rows", value: $session.rowLimit, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.ui(11, design: .monospaced))
                .frame(width: 72)
                .help("Preview row limit")

            if session.classification.requiresRecovery {
                Button {
                    Task { await session.prepareRecovery(connection: selectedConnection) }
                } label: {
                    Label("Recovery", systemImage: "arrow.uturn.backward.circle")
                }
                .controlSize(.small)
                .disabled(!canExecute)
                .help("Prepare rollback or restore instructions before running")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Stanford.cardBackground.opacity(0.45))
    }

    private var queryEditor: some View {
        TextEditor(text: Binding(
            get: { session.sql },
            set: { session.updateSelectedSQL($0) }
        ))
        .font(Stanford.ui(13, design: .monospaced))
        .scrollContentBackground(.hidden)
        .background(Stanford.cardBackground.opacity(0.32))
        .overlay(alignment: .topTrailing) {
            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
            }
        }
    }

    private var resultTabs: some View {
        Picker("", selection: $selectedTab) {
            ForEach(QueryShelfTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .results:
            resultsView
        case .chart:
            chartView
        case .explain:
            explainView
        case .history:
            historyView
        case .schema:
            schemaView
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if let errorMessage = session.errorMessage {
            ContentUnavailableView {
                Label("Query failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = session.executionResult {
            QueryResultGrid(result: result)
        } else {
            ContentUnavailableView {
                Label("No results", systemImage: "tablecells")
            } description: {
                Text("Dry run validates SQL. Run shows a limited preview here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var chartView: some View {
        if let result = session.executionResult,
           let chart = QueryChartModel(result: result) {
            QueryBarPreview(chart: chart)
        } else {
            ContentUnavailableView {
                Label("Chart preview", systemImage: "chart.bar.xaxis")
            } description: {
                Text("Run a query with one text-like column and one numeric column to preview a quick bar chart.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var explainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                QueryFactRow(title: "Connection", value: selectedConnection.displayName, systemImage: "cylinder")
                QueryFactRow(title: "Dialect", value: session.selectedDialect.displayName, systemImage: "text.badge.checkmark")
                QueryFactRow(title: "Classification", value: session.classification.displayName, systemImage: classificationIcon)
                if let dryRun = session.dryRunResult {
                    QueryFactRow(title: "Dry run", value: dryRun.message, systemImage: "checkmark.seal")
                    if let bytes = dryRun.bytesProcessed {
                        QueryFactRow(title: "Estimated bytes", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "externaldrive")
                    }
                }
                if let recoveryPlan = session.recoveryPlan {
                    QueryFactRow(title: recoveryPlan.title, value: recoveryPlan.details, systemImage: recoveryPlan.isPrepared ? "checkmark.shield" : "shield.lefthalf.filled")
                    QueryFactRow(title: "Restore SQL", value: recoveryPlan.restoreSQL, systemImage: "arrow.uturn.backward")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyView: some View {
        List(session.history) { entry in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label(entry.status.displayName, systemImage: entry.status.systemImage)
                        .font(Stanford.ui(12, weight: .semibold))
                    Text(entry.connectionName)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.createdAt, style: .time)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                Text(entry.sql)
                    .font(Stanford.ui(11, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                if let error = entry.errorMessage {
                    Text(error)
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.cardinalRed)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }

    private var schemaView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Schema", systemImage: "list.bullet.rectangle")
                    .font(Stanford.ui(12, weight: .semibold))
                if session.isLoadingSchema {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    loadSchema(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(selectedConnection.id == DatabaseConnection.editOnly.id || session.isLoadingSchema)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            if selectedConnection.id == DatabaseConnection.editOnly.id {
                ContentUnavailableView {
                    Label("Choose a connection", systemImage: "cylinder")
                } description: {
                    Text("Schema browsing needs a database connection.")
                }
            } else if let catalog = session.schemaCatalog, !catalog.datasets.isEmpty {
                HSplitView {
                    List(selection: $selectedSchemaTableID) {
                        ForEach(catalog.datasets) { dataset in
                            Section(dataset.displayName) {
                                ForEach(dataset.tables) { table in
                                    Label(table.tableID, systemImage: table.type == "VIEW" ? "tablecells.badge.ellipsis" : "tablecells")
                                        .tag(table.id)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 220, idealWidth: 260)

                    schemaDetail(catalog: catalog)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error = session.schemaErrorMessage {
                ContentUnavailableView {
                    Label("Schema unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                ContentUnavailableView {
                    Label("No schema loaded", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Refresh to list datasets, tables, and columns.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canExecute: Bool {
        hasRunnableSQL && !session.isRunning && selectedConnection.id != DatabaseConnection.editOnly.id
    }

    private var canRun: Bool {
        canExecute && (!session.requiresPreparedRecovery || session.hasPreparedRecovery)
    }

    private var runHelp: String {
        if session.requiresPreparedRecovery && !session.hasPreparedRecovery {
            return "Prepare recovery before running mutations"
        }
        return "Run query"
    }

    private var classificationIcon: String {
        switch session.classification {
        case .read: "checkmark.shield"
        case .ddl, .dml: "exclamationmark.triangle"
        case .script: "curlybraces.square"
        case .unknown: "questionmark.circle"
        }
    }

    private var classificationColor: Color {
        switch session.classification {
        case .read: Stanford.statusHealthy
        case .ddl, .dml, .script: Stanford.poppy
        case .unknown: Stanford.coolGrey
        }
    }

    private var safetyMessage: String {
        if selectedConnection.id == DatabaseConnection.editOnly.id {
            return "Choose a connection to dry run or execute."
        }
        if session.classification.requiresRecovery {
            if session.hasPreparedRecovery {
                return "Recovery prepared. Mutation can run with restore SQL recorded."
            }
            return "Writes, DDL, scripts, and unknown SQL require prepared recovery before run."
        }
        return "Read-only query. Dry run before executing to verify cost and syntax."
    }

    @ViewBuilder
    private func schemaDetail(catalog: SchemaCatalog) -> some View {
        if let table = selectedSchemaTable(in: catalog) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.tableID)
                            .font(Stanford.ui(13, weight: .semibold))
                            .lineLimit(1)
                        Text(table.fullName.replacingOccurrences(of: ":", with: "."))
                            .font(Stanford.caption(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        session.insertTableName(table)
                    } label: {
                        Label("Insert Table", systemImage: "plus.square.on.square")
                    }
                    .controlSize(.small)
                    Button {
                        Task { await session.loadTableSchema(table, connection: selectedConnection) }
                    } label: {
                        Label(table.columns.isEmpty ? "Load Columns" : "Reload", systemImage: "arrow.down.doc")
                    }
                    .controlSize(.small)
                    .disabled(session.isLoadingSchema)
                }
                .padding(14)

                Divider()

                if let error = session.tableSchemaErrorMessage,
                   session.tableSchemaErrorTableID == table.id,
                   table.columns.isEmpty {
                    ContentUnavailableView {
                        Label("Columns unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button {
                            Task { await session.loadTableSchema(table, connection: selectedConnection) }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .disabled(session.isLoadingSchema)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if table.columns.isEmpty {
                    ContentUnavailableView {
                        Label("Columns not loaded", systemImage: "rectangle.and.text.magnifyingglass")
                    } description: {
                        Text("Load columns to inspect fields or insert a column list.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack {
                        Text("\(table.columns.count) \(table.columns.count == 1 ? "column" : "columns")")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            session.insertColumns(table.columns)
                        } label: {
                            Label("Insert Columns", systemImage: "text.insert")
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Stanford.cardBackground.opacity(0.45))

                    if let error = session.tableSchemaErrorMessage,
                       session.tableSchemaErrorTableID == table.id {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.cardinalRed)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }

                    List(table.columns) { column in
                        HStack(spacing: 10) {
                            Text(column.name)
                                .font(Stanford.ui(12, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text(column.type)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                            if let mode = column.mode {
                                Text(mode)
                                    .font(Stanford.caption(10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Insert Column") {
                                session.insertColumns([column])
                            }
                            Button("Copy Column Name") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(column.name, forType: .string)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Select a table", systemImage: "tablecells")
            } description: {
                Text("Choose a table to inspect columns and insert references into the editor.")
            }
        }
    }

    private func selectedSchemaTable(in catalog: SchemaCatalog) -> SchemaTable? {
        let tables = catalog.datasets.flatMap(\.tables)
        if let selectedSchemaTableID,
           let table = tables.first(where: { $0.id == selectedSchemaTableID }) {
            return table
        }
        return tables.first
    }

    private func loadSchema(force: Bool) {
        guard selectedConnection.id != DatabaseConnection.editOnly.id else { return }
        guard force || session.schemaCatalog == nil else { return }
        Task { await session.loadSchema(connection: selectedConnection) }
    }

    private func normalizeConnection() {
        session.selectConnectionIfNeeded(from: connections)
        syncDialectWithSelectedConnection()
    }

    private func syncDialectWithSelectedConnection() {
        let dialect = selectedConnection.dialect
        if dialect != .unknown {
            session.selectedDialect = dialect
        }
    }
}

private enum QueryShelfTab: String, CaseIterable, Identifiable {
    case results
    case chart
    case explain
    case history
    case schema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .results: "Results"
        case .chart: "Chart"
        case .explain: "Explain"
        case .history: "History"
        case .schema: "Schema"
        }
    }

    var systemImage: String {
        switch self {
        case .results: "tablecells"
        case .chart: "chart.bar.xaxis"
        case .explain: "doc.text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .schema: "list.bullet.rectangle"
        }
    }
}

private struct QueryResultGrid: View {
    let result: QueryExecutionResult

    var body: some View {
        VStack(spacing: 0) {
            resultSummary
            GeometryReader { proxy in
                let widths = columnWidths(availableWidth: max(proxy.size.width - 40, 320))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                                QueryResultRow(
                                    rowNumber: index + 1,
                                    row: row,
                                    widths: widths,
                                    isAlternate: index.isMultiple(of: 2)
                                )
                            }
                        } header: {
                            QueryResultHeader(columns: result.columns, widths: widths)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .background(Color.primary.opacity(0.018))
            }
        }
    }

    private var resultSummary: some View {
        HStack(spacing: 12) {
            Label(result.message, systemImage: "checkmark.circle")
                .foregroundStyle(Stanford.statusHealthy)
                .lineLimit(1)

            Spacer(minLength: 8)

            QueryResultMetric(value: "\(result.rowCount)", label: result.rowCount == 1 ? "row" : "rows")
            QueryResultMetric(value: "\(result.columns.count)", label: result.columns.count == 1 ? "column" : "columns")

            if let bytes = result.bytesProcessed {
                QueryResultMetric(value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), label: "processed")
            }

            if let elapsed = result.elapsedMilliseconds {
                QueryResultMetric(value: "\(elapsed) ms", label: "elapsed")
            }

            Button {
                copy(result.csvString)
            } label: {
                Label("Copy CSV", systemImage: "tablecells.badge.ellipsis")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(result.rows.isEmpty)
            .help("Copy preview rows as CSV")
        }
        .font(Stanford.caption(11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func columnWidths(availableWidth: CGFloat) -> [CGFloat] {
        guard !result.columns.isEmpty else { return [] }

        let rawWidths = result.columns.indices.map { index in
            let header = result.columns[index].name
            let samples = result.rows.prefix(20).compactMap { row in
                index < row.count ? row[index] : nil
            }
            let longest = ([header] + samples)
                .map { min($0.count, 52) }
                .max() ?? header.count
            let hasStructuredValue = samples.contains { $0.isLikelyStructuredValue }
            let hasLongValue = samples.contains { $0.count > 36 || $0.contains("\n") }
            let base = CGFloat(longest * 7 + 34)
            let maxWidth: CGFloat = hasStructuredValue ? 360 : (hasLongValue ? 300 : 240)
            return min(max(base, 136), maxWidth)
        }

        let rowNumberWidth: CGFloat = 52
        let total = rawWidths.reduce(rowNumberWidth, +)
        guard total < availableWidth else { return rawWidths }

        let extra = (availableWidth - total) / CGFloat(rawWidths.count)
        return rawWidths.map { min($0 + extra, 380) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct QueryResultMetric: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Stanford.ui(11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

private struct QueryResultHeader: View {
    let columns: [QueryResultColumn]
    let widths: [CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 52, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .foregroundStyle(.secondary)

            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(column.name)
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: widths[safe: index] ?? 160, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                    }
            }
        }
        .font(Stanford.caption(11))
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }
}

private struct QueryResultRow: View {
    let rowNumber: Int
    let row: [String]
    let widths: [CGFloat]
    let isAlternate: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(rowNumber.formatted())
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)

            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                QueryResultCell(value: value, width: widths[safe: index] ?? 160)
            }
        }
        .background(isAlternate ? Stanford.cardBackground.opacity(0.72) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(height: 1)
        }
    }
}

private struct QueryResultCell: View {
    let value: String
    let width: CGFloat

    var body: some View {
        Text(displayValue)
            .font(Stanford.ui(12, design: value.isLikelyStructuredValue ? .monospaced : .default))
            .foregroundStyle(value.isEmpty ? .secondary : .primary)
            .lineLimit(value.isLikelyStructuredValue ? 5 : 3)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1)
            }
            .contextMenu {
                Button("Copy Value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            .help(value)
    }

    private var displayValue: String {
        value.isEmpty ? "NULL" : value
    }
}

private extension QueryExecutionResult {
    var csvString: String {
        let header = columns.map(\.name).map(csvEscaped).joined(separator: ",")
        let body = rows.map { row in
            row.map(csvEscaped).joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\n")
    }

    private func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension String {
    var isLikelyStructuredValue: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || contains("\n")
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct QueryChartModel {
    let labels: [String]
    let values: [Double]

    init?(result: QueryExecutionResult) {
        guard result.columns.count >= 2,
              let numericIndex = result.rows.first?.indices.first(where: { index in
                  result.rows.contains { row in
                      guard index < row.count else { return false }
                      return Double(row[index]) != nil
                  }
              }) else {
            return nil
        }
        let labelIndex = result.rows.first?.indices.first { $0 != numericIndex } ?? 0
        let pairs = result.rows.compactMap { row -> (String, Double)? in
            guard labelIndex < row.count,
                  numericIndex < row.count,
                  let value = Double(row[numericIndex]) else {
                return nil
            }
            return (row[labelIndex], value)
        }
        guard !pairs.isEmpty else { return nil }
        labels = pairs.prefix(12).map(\.0)
        values = pairs.prefix(12).map(\.1)
    }
}

private struct QueryBarPreview: View {
    let chart: QueryChartModel

    private var maxValue: Double {
        max(chart.values.max() ?? 1, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(zip(chart.labels, chart.values)), id: \.0) { label, value in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Stanford.lagunita.opacity(0.82))
                                .frame(width: max(3, proxy.size.width * CGFloat(value / maxValue)))
                        }
                        .frame(height: 18)
                        Text(value.formatted(.number.precision(.fractionLength(0...2))))
                            .font(Stanford.ui(11, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct QueryFactRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Stanford.ui(12, weight: .semibold))
                Text(value)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct QueryShelfToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.55 : 0.82))
            .frame(minWidth: 28, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension QueryExecutionStatus {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .dryRunSucceeded: "Dry run"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .blocked: "Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil"
        case .dryRunSucceeded: "checkmark.seal"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .blocked: "hand.raised"
        }
    }
}
