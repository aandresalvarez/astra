import SwiftUI
import SwiftData

struct ShelfQueryPanelView: View {
    @ObservedObject var session: ShelfQuerySession
    let workspace: Workspace?
    let task: AgentTask?
    let utilityRuntime: AgentUtilityRuntimeConfiguration
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
            queryPanel
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

            moreMenu

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close query shelf")
            .buttonStyle(QueryShelfToolbarButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var workflowConnectionMenu: some View {
        Menu {
            ForEach(connections) { connection in
                Button {
                    session.selectedConnectionID = connection.id
                } label: {
                    Label(
                        connection.displayName,
                        systemImage: selectedConnection.id == connection.id ? "checkmark" : "cylinder"
                    )
                }
            }
        } label: {
            QueryWorkflowFieldLabel(
                title: "Connection",
                value: selectedConnection.displayName
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QueryWorkflowFieldButtonStyle())
        .frame(maxWidth: 230)
        .help("Database connection")
    }

    private var workflowDialectMenu: some View {
        Menu {
            ForEach(SQLDialect.allCases.filter { $0 != .unknown }) { dialect in
                Button {
                    session.selectedDialect = dialect
                } label: {
                    Label(
                        dialect.displayName,
                        systemImage: session.selectedDialect == dialect ? "checkmark" : "text.badge.checkmark"
                    )
                }
            }
        } label: {
            QueryWorkflowFieldLabel(
                title: "SQL flavor",
                value: shortDialectName(session.selectedDialect)
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QueryWorkflowFieldButtonStyle())
        .frame(maxWidth: 150)
        .help("SQL dialect")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                session.newScratchQuery(sql: "-- Write SQL here\n", title: "Untitled Query")
            } label: {
                Label("New query", systemImage: "plus")
            }

            Divider()

            Button {
                session.saveSelectedDocument()
            } label: {
                Label("Save SQL file", systemImage: "square.and.arrow.down")
            }
            .disabled(!session.canSaveSelectedDocument)
            .keyboardShortcut("s", modifiers: .command)

            Button {
                session.copySQLToPasteboard()
            } label: {
                Label("Copy SQL", systemImage: "doc.on.doc")
            }
            .disabled(!hasRunnableSQL)

            Button {
                formatSQL()
            } label: {
                Label("Format SQL", systemImage: "text.alignleft")
            }
            .disabled(!hasRunnableSQL || session.isRunning)

            Divider()

            Button {
                selectedTab = .brief
                generateBrief()
            } label: {
                Label("Generate AI Brief", systemImage: "sparkles")
            }
            .disabled(!hasRunnableSQL || session.isGeneratingBrief)

            Button {
                selectedTab = .explain
                validateAndRepair()
            } label: {
                Label("Validate and repair SQL", systemImage: "wand.and.stars")
            }
            .disabled(!canSelfHeal)

            if session.executionResult != nil {
                Button {
                    selectedTab = .explain
                    explainResult()
                } label: {
                    Label("Explain result", systemImage: "text.magnifyingglass")
                }
                .disabled(session.isExplainingResult)
            }
        } label: {
            QueryShelfToolbarMenuLabel(title: "Actions", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QueryShelfToolbarButtonStyle())
        .help("Query actions")
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

    private var queryPanel: some View {
        VStack(spacing: 0) {
            querySetupBar
            Divider()
            queryEditor
                .frame(minHeight: 220)
            Divider()
            queryActionBar
        }
        .background(Stanford.cardBackground.opacity(0.28))
    }

    private var querySetupBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                querySetupSummary
                Spacer(minLength: 12)
                workflowConnectionMenu
                workflowDialectMenu
                rowLimitField
                formatSQLButton
            }

            VStack(alignment: .leading, spacing: 8) {
                querySetupSummary
                HStack(spacing: 8) {
                    workflowConnectionMenu
                    workflowDialectMenu
                    rowLimitField
                    formatSQLButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var querySetupSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SQL setup")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Circle()
                    .fill(classificationColor)
                    .frame(width: 7, height: 7)
                Text(session.classification.displayName)
                    .foregroundStyle(classificationColor)
                Text(setupWorkflowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(Stanford.caption(11))
        }
        .layoutPriority(1)
    }

    private var queryActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                queryActionSummary
                Spacer(minLength: 12)
                queryCheckControls
                runControl
            }

            VStack(alignment: .leading, spacing: 8) {
                queryActionSummary
                HStack(spacing: 8) {
                    queryCheckControls
                    runControl
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var queryActionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Check and run")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.primary)
            Text(actionWorkflowSubtitle)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .layoutPriority(1)
    }

    private var queryCheckControls: some View {
        HStack(spacing: 8) {
            if session.classification.requiresRecovery {
                recoveryButton
                gateApprovalControl
            } else {
                dryRunButton
            }

            if session.canRestoreSelfHealingOriginalSQL {
                Button {
                    session.restoreSelfHealingOriginalSQL()
                } label: {
                    Text("Restore SQL")
                }
                .buttonStyle(QueryWorkflowSecondaryButtonStyle())
                .disabled(session.isRunning)
                .help("Restore the SQL from before AI repair")
            }
        }
    }

    private var runControl: some View {
        Button {
            Task { await session.run(connection: selectedConnection) }
        } label: {
            if session.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Label(runButtonTitle, systemImage: "play.fill")
            }
        }
        .disabled(!canRun)
        .help(runHelp)
        .buttonStyle(QueryShelfActionButtonStyle(isPrimary: true))
    }

    private var rowLimitField: some View {
        HStack(spacing: 6) {
            Text("Rows")
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Rows", value: $session.rowLimit, format: .number)
                .textFieldStyle(.plain)
                .font(Stanford.ui(11, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .help("Preview row limit")
    }

    private var formatSQLButton: some View {
        Button {
            formatSQL()
        } label: {
            Label("Format", systemImage: "text.alignleft")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(QueryWorkflowSecondaryButtonStyle())
        .disabled(!hasRunnableSQL || session.isRunning)
        .help("Auto-format SQL")
    }

    private var dryRunButton: some View {
        Button {
            Task { await session.dryRun(connection: selectedConnection) }
        } label: {
            Text(dryRunButtonTitle)
        }
        .disabled(!canExecute)
        .help("Dry run query")
        .buttonStyle(QueryWorkflowSecondaryButtonStyle())
    }

    private var recoveryButton: some View {
        Button {
            Task { await session.prepareRecovery(connection: selectedConnection) }
        } label: {
            Text(session.hasCurrentPreparedRecovery(connection: selectedConnection) ? "Refresh Recovery" : "Prepare Recovery")
        }
        .disabled(!canExecute)
        .help("Prepare rollback or restore instructions before running")
        .buttonStyle(QueryWorkflowSecondaryButtonStyle())
    }

    @ViewBuilder
    private var gateApprovalControl: some View {
        if session.hasCurrentPreparedRecovery(connection: selectedConnection) &&
            !session.hasApprovedSafetyGate(connection: selectedConnection) {
            Button {
                session.approveSafetyGate(connection: selectedConnection)
            } label: {
                Text("Approve Gate")
            }
            .disabled(!canExecute)
            .help("Approve this exact SQL and prepared recovery plan for execution")
            .buttonStyle(QueryWorkflowSecondaryButtonStyle())
        } else if session.hasApprovedSafetyGate(connection: selectedConnection) {
            Text("Gate approved")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(Stanford.statusHealthy)
                .padding(.horizontal, 8)
                .frame(height: 30)
        }
    }

    private var queryEditor: some View {
        SQLQueryEditorView(text: Binding(
            get: { session.sql },
            set: { session.updateSelectedSQL($0) }
        ))
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
        case .brief:
            briefView
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
    private var briefView: some View {
        if session.isGeneratingBrief {
            ContentUnavailableView {
                Label("Generating AI Brief", systemImage: "sparkles")
            } description: {
                Text("ASTRA is reviewing the task context, SQL, schema, and dry-run state.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let brief = session.aiBrief {
            QueryBriefView(
                brief: brief,
                onRefresh: generateBrief
            )
        } else if let error = session.aiBriefErrorMessage {
            ContentUnavailableView {
                Label("AI Brief unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button {
                    generateBrief()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .disabled(!hasRunnableSQL)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("AI Brief", systemImage: "sparkles")
            } description: {
                Text("Generate a short intent, assumption, risk, and trust-check summary for this SQL.")
            } actions: {
                Button {
                    generateBrief()
                } label: {
                    Label("Generate Brief", systemImage: "sparkles")
                }
                .disabled(!hasRunnableSQL)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            QueryResultGrid(
                result: result,
                isExplainingResult: session.isExplainingResult,
                onExplain: {
                    selectedTab = .explain
                    explainResult()
                }
            )
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
                if let safetyGate = session.safetyGateReview {
                    QuerySafetyGateView(
                        review: safetyGate,
                        isCurrentApproval: session.hasApprovedSafetyGate(connection: selectedConnection),
                        onApprove: session.hasCurrentPreparedRecovery(connection: selectedConnection) &&
                            !session.hasApprovedSafetyGate(connection: selectedConnection)
                            ? { session.approveSafetyGate(connection: selectedConnection) }
                            : nil
                    )
                }
                if !session.validationSteps.isEmpty {
                    QueryValidationTrailView(
                        steps: session.validationSteps,
                        onRestore: session.canRestoreSelfHealingOriginalSQL ? { session.restoreSelfHealingOriginalSQL() } : nil
                    )
                }
                if let result = session.executionResult {
                    QueryResultExplanationView(
                        result: result,
                        explanation: session.resultExplanation,
                        errorMessage: session.resultExplanationErrorMessage,
                        isLoading: session.isExplainingResult,
                        onGenerate: explainResult
                    )
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

    private var canSelfHeal: Bool {
        hasRunnableSQL &&
            !session.isRunning &&
            !session.isGeneratingBrief &&
            !session.isExplainingResult &&
            selectedConnection.id != DatabaseConnection.editOnly.id
    }

    private var canRun: Bool {
        canExecute &&
            (!session.requiresPreparedRecovery ||
                (session.hasCurrentPreparedRecovery(connection: selectedConnection) &&
                    session.hasApprovedSafetyGate(connection: selectedConnection)))
    }

    private var setupWorkflowSubtitle: String {
        if selectedConnection.id == DatabaseConnection.editOnly.id {
            return "Choose a database before checking or running."
        }
        return "\(shortDialectName(session.selectedDialect)) SQL, limited to \(session.rowLimit) rows."
    }

    private var checkWorkflowSubtitle: String {
        if session.classification.requiresRecovery {
            if session.hasApprovedSafetyGate(connection: selectedConnection) {
                return "Recovery is prepared and the gate is approved."
            }
            if session.hasCurrentPreparedRecovery(connection: selectedConnection) {
                return "Recovery is ready. Approve the gate before running."
            }
            return "This SQL can change data. Prepare recovery first."
        }
        if let dryRun = session.dryRunResult {
            if let bytes = dryRun.bytesProcessed {
                return "Dry run passed. \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) estimated."
            }
            return "Dry run passed. \(dryRun.message)"
        }
        return "Validate syntax and estimated cost before running."
    }

    private var actionWorkflowSubtitle: String {
        if !canExecute {
            return "Write SQL and choose a connection before checking or running."
        }
        if session.classification.requiresRecovery {
            return checkWorkflowSubtitle
        }
        if session.dryRunResult == nil {
            return "Dry run validates syntax and estimated cost. Run shows a limited preview."
        }
        return checkWorkflowSubtitle
    }

    private var checkWorkflowColor: Color {
        if session.classification.requiresRecovery {
            return session.hasApprovedSafetyGate(connection: selectedConnection) ? Stanford.statusHealthy : Stanford.poppy
        }
        return session.dryRunResult == nil ? Stanford.coolGrey : Stanford.statusHealthy
    }

    private var runWorkflowSubtitle: String {
        if !canExecute {
            return "Write SQL and choose a connection first."
        }
        if session.requiresPreparedRecovery {
            return runHelp
        }
        if session.dryRunResult == nil {
            return "Run a limited preview. Dry run is recommended first."
        }
        return "Run a limited preview using the checked SQL."
    }

    private var dryRunButtonTitle: String {
        session.dryRunResult == nil ? "Dry Run" : "Run Again"
    }

    private var runButtonTitle: String {
        session.classification == .read ? "Run Preview" : "Run Change"
    }

    private var runHelp: String {
        if session.requiresPreparedRecovery {
            if !session.hasCurrentPreparedRecovery(connection: selectedConnection) {
                return "Prepare recovery before running mutations"
            }
            if !session.hasApprovedSafetyGate(connection: selectedConnection) {
                return "Approve the safe execution gate before running"
            }
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
            if session.hasApprovedSafetyGate(connection: selectedConnection) {
                return "Safe execution gate approved for this SQL and recovery plan."
            }
            if session.hasCurrentPreparedRecovery(connection: selectedConnection) {
                return "Recovery prepared. Approve the safe execution gate before running."
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

    private func generateBrief() {
        let generator = AgentQueryBriefGenerator(
            workspacePath: briefWorkspacePath,
            utilityRuntime: utilityRuntime
        )
        Task {
            await session.generateBrief(
                connection: selectedConnection,
                taskContext: briefTaskContext,
                generator: generator
            )
        }
    }

    private func validateAndRepair() {
        let generator = AgentQueryRepairGenerator(
            workspacePath: briefWorkspacePath,
            utilityRuntime: utilityRuntime
        )
        Task {
            await session.validateAndRepair(
                connection: selectedConnection,
                taskContext: briefTaskContext,
                repairGenerator: generator
            )
        }
    }

    private func formatSQL() {
        let formattedSQL = SQLFormatter.format(session.sql)
        guard formattedSQL != session.sql else { return }
        session.updateSelectedSQL(formattedSQL)
    }

    private func explainResult() {
        let generator = AgentQueryResultExplanationGenerator(
            workspacePath: briefWorkspacePath,
            utilityRuntime: utilityRuntime
        )
        Task {
            await session.explainResult(
                connection: selectedConnection,
                taskContext: briefTaskContext,
                generator: generator
            )
        }
    }

    private var briefTaskContext: QueryBriefTaskContext? {
        guard task != nil || workspace != nil else { return nil }
        return QueryBriefTaskContext(
            taskTitle: task?.title ?? "",
            taskGoal: task?.goal ?? "",
            workspaceName: workspace?.name ?? ""
        )
    }

    private var briefWorkspacePath: String {
        if let task, !task.codeWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return task.codeWorkingDirectory
        }
        if let path = workspace?.primaryPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return FileManager.default.currentDirectoryPath
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

    private func shortDialectName(_ dialect: SQLDialect) -> String {
        switch dialect {
        case .bigQueryStandard: "BigQuery"
        case .postgres: "Postgres"
        case .snowflake: "Snowflake"
        case .duckDB: "DuckDB"
        case .sqlite: "SQLite"
        case .unknown: "SQL"
        }
    }
}

private enum QueryShelfTab: String, CaseIterable, Identifiable {
    case brief
    case results
    case chart
    case explain
    case history
    case schema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: "Brief"
        case .results: "Results"
        case .chart: "Chart"
        case .explain: "Explain"
        case .history: "History"
        case .schema: "Schema"
        }
    }

    var systemImage: String {
        switch self {
        case .brief: "sparkles"
        case .results: "tablecells"
        case .chart: "chart.bar.xaxis"
        case .explain: "doc.text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .schema: "list.bullet.rectangle"
        }
    }
}

private struct QueryBriefView: View {
    let brief: QueryBrief
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI Brief", systemImage: "sparkles")
                            .font(Stanford.ui(13, weight: .semibold))
                            .foregroundStyle(Stanford.lagunita)
                        Text(brief.goal)
                            .font(Stanford.ui(15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    QueryBriefRiskBadge(risk: brief.risk)
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Regenerate AI Brief")
                }

                HStack(spacing: 8) {
                    if !brief.grain.isEmpty {
                        QueryBriefChip(title: "Grain", value: brief.grain, systemImage: "square.grid.3x3")
                    }
                    if !brief.estimatedCost.isEmpty {
                        QueryBriefChip(title: "Cost", value: brief.estimatedCost, systemImage: "externaldrive")
                    }
                }

                QueryBriefSection(title: "Assumptions", systemImage: "questionmark.bubble", values: brief.assumptions)
                QueryBriefSection(title: "Tables", systemImage: "tablecells", values: brief.tables)
                QueryBriefSection(title: "Columns", systemImage: "rectangle.and.text.magnifyingglass", values: brief.columns)
                QueryBriefSection(title: "Filters", systemImage: "line.3.horizontal.decrease.circle", values: brief.filters)
                QueryBriefSection(title: "Joins", systemImage: "arrow.triangle.branch", values: brief.joins)

                if !brief.checks.isEmpty {
                    QueryBriefChecksView(checks: brief.checks)
                }

                QueryBriefSection(title: "Notes", systemImage: "note.text", values: brief.notes)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct QueryBriefRiskBadge: View {
    let risk: QueryBriefRisk

    var body: some View {
        Text(risk.displayName)
            .font(Stanford.ui(11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private var color: Color {
        switch risk {
        case .low: Stanford.statusHealthy
        case .medium: Stanford.poppy
        case .high: Stanford.cardinalRed
        case .unknown: Stanford.coolGrey
        }
    }
}

private struct QueryBriefChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label {
            Text("\(title): \(value)")
                .lineLimit(2)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(Stanford.ui(11, weight: .medium))
        .foregroundStyle(Stanford.lagunita)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Stanford.lagunita.opacity(0.10))
        )
        .textSelection(.enabled)
    }
}

private struct QueryBriefSection: View {
    let title: String
    let systemImage: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Stanford.cardBackground.opacity(0.72))
                            )
                    }
                }
            }
        }
    }
}

private struct QueryBriefChecksView: View {
    let checks: [QueryBriefTrustCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trust checks", systemImage: "checklist.checked")
                .font(Stanford.ui(12, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: systemImage(for: check.status))
                            .font(Stanford.ui(11, weight: .semibold))
                            .foregroundStyle(color(for: check.status))
                            .frame(width: 16)
                        Text(check.label)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Stanford.cardBackground.opacity(0.72))
                    )
                }
            }
        }
    }

    private func systemImage(for status: QueryBriefCheckStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(for status: QueryBriefCheckStatus) -> Color {
        switch status {
        case .passed: Stanford.statusHealthy
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        case .info: Stanford.lagunita
        }
    }
}

private struct QueryValidationTrailView: View {
    let steps: [QueryValidationStep]
    let onRestore: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Self-healing validation", systemImage: "wand.and.stars")
                    .font(Stanford.ui(12, weight: .semibold))
                Spacer()
                if let onRestore {
                    Button {
                        onRestore()
                    } label: {
                        Label("Restore Original", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: systemImage(for: step.status))
                            .font(Stanford.ui(11, weight: .semibold))
                            .foregroundStyle(color(for: step.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(Stanford.ui(11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(step.detail)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Stanford.cardBackground.opacity(0.72))
                    )
                }
            }
        }
    }

    private func systemImage(for status: QueryValidationStepStatus) -> String {
        switch status {
        case .running: "arrow.triangle.2.circlepath"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .repaired: "wand.and.stars"
        case .blocked: "hand.raised.fill"
        }
    }

    private func color(for status: QueryValidationStepStatus) -> Color {
        switch status {
        case .running: Stanford.lagunita
        case .passed: Stanford.statusHealthy
        case .failed, .blocked: Stanford.cardinalRed
        case .repaired: Stanford.poppy
        }
    }
}

private struct QueryResultExplanationView: View {
    let result: QueryExecutionResult
    let explanation: QueryResultExplanation?
    let errorMessage: String?
    let isLoading: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("AI result explanation", systemImage: "sparkles")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Spacer()
                Button {
                    onGenerate()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Label(explanation == nil ? "Explain Result" : "Refresh", systemImage: "sparkles")
                    }
                }
                .controlSize(.small)
                .disabled(isLoading)
            }

            HStack(spacing: 8) {
                QueryBriefChip(title: "Rows", value: "\(result.rowCount)", systemImage: "number")
                QueryBriefChip(title: "Columns", value: "\(result.columns.count)", systemImage: "tablecells")
                if let bytes = result.bytesProcessed {
                    QueryBriefChip(
                        title: "Processed",
                        value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                        systemImage: "externaldrive"
                    )
                }
            }

            if isLoading {
                QueryFactRow(
                    title: "Explaining result",
                    value: "ASTRA is reviewing the SQL, task context, returned rows, and schema context.",
                    systemImage: "sparkles"
                )
            } else if let explanation {
                VStack(alignment: .leading, spacing: 6) {
                    Text(explanation.headline)
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if !explanation.summary.isEmpty {
                        Text(explanation.summary)
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Stanford.cardBackground.opacity(0.72))
                )

                QueryBriefSection(title: "Key findings", systemImage: "chart.line.uptrend.xyaxis", values: explanation.keyFindings)
                QueryBriefSection(title: "Anomalies", systemImage: "exclamationmark.triangle", values: explanation.anomalies)
                QueryBriefSection(title: "Caveats", systemImage: "hand.raised", values: explanation.caveats)
                QueryBriefSection(title: "Follow-ups", systemImage: "arrow.triangle.branch", values: explanation.followUps)
                if !explanation.checks.isEmpty {
                    QueryBriefChecksView(checks: explanation.checks)
                }
            } else if let errorMessage {
                QueryFactRow(title: "Explanation unavailable", value: errorMessage, systemImage: "exclamationmark.triangle")
            } else {
                QueryFactRow(
                    title: "Explain this result",
                    value: "Generate a concise interpretation of the returned preview rows, caveats, and useful follow-up questions.",
                    systemImage: "sparkles"
                )
            }
        }
    }
}

private struct QuerySafetyGateView: View {
    let review: QuerySafetyGateReview
    let isCurrentApproval: Bool
    let onApprove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Safe execution gate", systemImage: isCurrentApproval ? "checkmark.shield" : "lock.shield")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(isCurrentApproval ? Stanford.statusHealthy : Stanford.poppy)
                Spacer()
                if let onApprove {
                    Button {
                        onApprove()
                    } label: {
                        Label("Approve Gate", systemImage: "lock.open.trianglebadge.exclamationmark")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                QueryBriefChip(title: "Connection", value: review.connectionName, systemImage: "cylinder")
                QueryBriefChip(title: "Class", value: review.classification.displayName, systemImage: "exclamationmark.triangle")
                QueryBriefChip(title: "Dialect", value: review.dialect.displayName, systemImage: "text.badge.checkmark")
            }

            if let approvedAt = review.approvedAt {
                QueryFactRow(
                    title: "Approval",
                    value: "Approved at \(approvedAt.formatted(date: .omitted, time: .standard))",
                    systemImage: "checkmark.seal"
                )
            }

            QueryFactRow(title: review.recoveryTitle, value: review.recoveryDetails, systemImage: "arrow.uturn.backward.circle")

            if let source = review.sourceTableID, !source.isEmpty {
                QueryFactRow(title: "Affected object", value: source, systemImage: "tablecells.badge.ellipsis")
            }
            if let backup = review.backupTableID, !backup.isEmpty {
                QueryFactRow(title: "Backup object", value: backup, systemImage: "externaldrive.badge.checkmark")
            }
            if !review.restoreSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                QueryFactRow(title: "Restore SQL", value: review.restoreSQL, systemImage: "arrow.uturn.backward")
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(review.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: systemImage(for: check.status))
                            .font(Stanford.ui(11, weight: .semibold))
                            .foregroundStyle(color(for: check.status))
                            .frame(width: 16)
                        Text(check.label)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Stanford.cardBackground.opacity(0.72))
                    )
                }
            }
        }
    }

    private func systemImage(for status: QuerySafetyGateCheckStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func color(for status: QuerySafetyGateCheckStatus) -> Color {
        switch status {
        case .passed: Stanford.statusHealthy
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        }
    }
}

private struct QueryResultGrid: View {
    let result: QueryExecutionResult
    let isExplainingResult: Bool
    let onExplain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            resultSummary
            Divider()
            GeometryReader { proxy in
                let availableWidth = max(proxy.size.width - QueryResultGridLayout.outerPadding * 2, 320)
                let availableHeight = max(proxy.size.height - QueryResultGridLayout.outerPadding * 2, 0)
                let widths = columnWidths(availableWidth: availableWidth)
                let tableWidth = totalTableWidth(widths)
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                if result.rows.isEmpty {
                                    QueryResultEmptyRow(width: tableWidth)
                                } else {
                                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                                        QueryResultRow(
                                            rowNumber: index + 1,
                                            row: row,
                                            widths: widths,
                                            isAlternate: !index.isMultiple(of: 2)
                                        )
                                    }
                                }
                            } header: {
                                QueryResultHeader(columns: result.columns, widths: widths)
                            }
                        }
                        .frame(width: tableWidth, alignment: .topLeading)
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: QueryResultGridLayout.cornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: QueryResultGridLayout.cornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.025), radius: 6, x: 0, y: 2)
                    }
                    .frame(minWidth: availableWidth, minHeight: availableHeight, alignment: .topLeading)
                    .padding(QueryResultGridLayout.outerPadding)
                }
                .background(Stanford.fog.opacity(0.42))
            }
        }
        .background(Stanford.panelBackground)
    }

    private var resultSummary: some View {
        HStack(spacing: 12) {
            Label(result.message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Stanford.statusHealthy)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                QueryResultMetric(value: "\(result.rowCount)", label: result.rowCount == 1 ? "row" : "rows")
                QueryResultMetric(value: "\(result.columns.count)", label: result.columns.count == 1 ? "column" : "columns")

                if let bytes = result.bytesProcessed {
                    QueryResultMetric(value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), label: "processed")
                }

                if let elapsed = result.elapsedMilliseconds {
                    QueryResultMetric(value: "\(elapsed) ms", label: "elapsed")
                }
            }

            Button {
                onExplain()
            } label: {
                if isExplainingResult {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Label("Explain", systemImage: "sparkles")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(isExplainingResult)
            .help("Explain the returned preview with AI")

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
            let base = CGFloat(longest * 7 + 52)
            let maxWidth: CGFloat = hasStructuredValue ? 420 : (hasLongValue ? 340 : 260)
            return min(max(base, 148), maxWidth)
        }

        let contentWidth = rawWidths.reduce(0, +)
        let targetContentWidth = max(availableWidth - QueryResultGridLayout.rowNumberWidth, contentWidth)
        guard contentWidth < targetContentWidth else { return rawWidths }

        let extra = targetContentWidth - contentWidth
        return rawWidths.map { width in
            let share = width / contentWidth
            return width + extra * share
        }
    }

    private func totalTableWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(QueryResultGridLayout.rowNumberWidth, +)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum QueryResultGridLayout {
    static let outerPadding: CGFloat = 16
    static let rowNumberWidth: CGFloat = 58
    static let cornerRadius: CGFloat = 8
    static let rowMinHeight: CGFloat = 38
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }
}

private struct QueryResultHeader: View {
    let columns: [QueryResultColumn]
    let widths: [CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(width: QueryResultGridLayout.rowNumberWidth, alignment: .trailing)
                .foregroundStyle(.secondary)

            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(column.name)
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(width: widths[safe: index] ?? 160, alignment: .leading)
            }
        }
        .font(Stanford.caption(11))
        .background(.thinMaterial)
        .overlay(alignment: .leading) {
            QueryResultColumnDividers(widths: widths, opacity: 0.08)
        }
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
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(width: QueryResultGridLayout.rowNumberWidth, alignment: .topTrailing)
                .frame(minHeight: QueryResultGridLayout.rowMinHeight, alignment: .topTrailing)

            ForEach(widths.indices, id: \.self) { index in
                let value = row[safe: index] ?? ""
                QueryResultCell(value: value, width: widths[safe: index] ?? 160)
            }
        }
        .background(isAlternate ? Stanford.fog.opacity(0.34) : Stanford.cardBackground)
        .overlay(alignment: .leading) {
            QueryResultColumnDividers(widths: widths, opacity: 0.055)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct QueryResultCell: View {
    let value: String
    let width: CGFloat

    var body: some View {
        cellContent
            .padding(.horizontal, 12)
            .padding(.vertical, value.isLikelyStructuredValue ? 9 : 10)
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: QueryResultGridLayout.rowMinHeight, alignment: .topLeading)
            .contextMenu {
                Button("Copy Value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            .help(value)
    }

    @ViewBuilder
    private var cellContent: some View {
        if value.isEmpty {
            Text("NULL")
                .font(Stanford.ui(10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .textSelection(.enabled)
        } else {
            Text(value.sqlResultPreview)
                .font(Stanford.ui(12, design: value.isLikelyStructuredValue ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(value.isLikelyStructuredValue ? 6 : 2)
                .textSelection(.enabled)
        }
    }
}

private struct QueryResultColumnDividers: View {
    let widths: [CGFloat]
    let opacity: Double

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: QueryResultGridLayout.rowNumberWidth)
            divider
            ForEach(Array(widths.dropLast().enumerated()), id: \.offset) { _, width in
                Color.clear
                    .frame(width: width)
                divider
            }
        }
        .allowsHitTesting(false)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity))
            .frame(width: 1)
    }
}

private struct QueryResultEmptyRow: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
            Text("Query returned no preview rows.")
                .foregroundStyle(.secondary)
        }
        .font(Stanford.caption(11))
        .frame(width: width)
        .frame(minHeight: 72)
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

    var sqlResultPreview: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyStructuredValue,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return self
        }
        return pretty
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

private struct QueryWorkflowStep<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    var statusColor: Color = Stanford.lagunita
    let content: Content

    init(
        number: Int,
        title: String,
        subtitle: String,
        statusColor: Color = Stanford.lagunita,
        @ViewBuilder content: () -> Content
    ) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.statusColor = statusColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(Stanford.ui(11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(statusColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            content
                .padding(.leading, 28)
        }
    }
}

private struct QueryWorkflowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 58)
            .padding(.top, 3)
    }
}

private struct QueryWorkflowFieldLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Stanford.ui(9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QueryWorkflowFieldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct QueryWorkflowSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.84 : 0.45))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.065))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct QueryShelfToolbarMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct QueryShelfActionButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foregroundColor: Color {
        if isPrimary {
            return .white
        }
        return Color.primary.opacity(isEnabled ? 0.82 : 0.45)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPrimary {
            return Stanford.lagunita.opacity(isPressed ? 0.82 : 1)
        }
        return Color.primary.opacity(isPressed ? 0.12 : 0.065)
    }
}

private struct QueryShelfToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.ui(13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.55 : 0.82))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
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
