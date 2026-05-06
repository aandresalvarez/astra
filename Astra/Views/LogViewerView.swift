import SwiftUI

struct LogViewerView: View {
    private static let maxVisibleEntries = 2000

    @State private var entries: [LogEntry] = AppLogger.entries
    @State private var filteredEntries: [LogEntry] = []
    @State private var pendingLiveEntries: [LogEntry] = []
    @State private var searchText = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var selectedCategory: String? = nil
    @State private var autoScroll = true
    @State private var filterTaskID: UUID? = nil
    @State private var isGeneratingDiagnostics = false
    @State private var diagnosticsMessage: String? = nil
    @State private var diagnosticsReportURL: URL? = nil
    @AppStorage(AppStorageKeys.diagnosticsScope) private var diagnosticsScopeRawValue = LogDiagnosticsScope.sinceLastReport.rawValue

    private let categories = [
        "App", "Audit", "Worker", "Queue", "UI", "Isolation", "Validation",
        "Reflection", "SSH", "Persistence", "PluginCatalog", "Scheduler",
        "Keychain", "Updater", "Performance", "Capabilities", "Diagnostics", "General"
    ]

    private var hasActiveFilters: Bool {
        selectedLevel != nil ||
            selectedCategory != nil ||
            filterTaskID != nil ||
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filtered(_ sourceEntries: [LogEntry]) -> [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sourceEntries.filter { entry in
            if let level = selectedLevel, entry.logLevel < level { return false }
            if let cat = selectedCategory, entry.category != cat { return false }
            if let tid = filterTaskID, entry.taskID != tid { return false }
            if !query.isEmpty {
                return entry.message.lowercased().contains(query)
                    || entry.category.lowercased().contains(query)
            }
            return true
        }
    }

    private func recomputeFilteredEntries(from sourceEntries: [LogEntry]? = nil) {
        let sourceEntries = sourceEntries ?? entries
        if hasActiveFilters {
            filteredEntries = PerformanceTelemetry.measure(
                "log_filter",
                thresholdMilliseconds: 10,
                fields: [
                    "entry_count": String(sourceEntries.count),
                    "has_query": String(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    "level_filter": selectedLevel?.rawValue ?? "none",
                    "category_filter": selectedCategory ?? "none"
                ]
            ) {
                filtered(sourceEntries)
            }
        } else {
            filteredEntries = sourceEntries
        }
    }

    private static func trimmedEntries(_ source: [LogEntry]) -> [LogEntry] {
        guard source.count > maxVisibleEntries else { return source }
        return Array(source.suffix(maxVisibleEntries))
    }

    private func flushPendingLiveEntries() {
        guard !pendingLiveEntries.isEmpty else { return }
        let nextEntries = Self.trimmedEntries(entries + pendingLiveEntries)
        pendingLiveEntries.removeAll(keepingCapacity: true)
        entries = nextEntries
        recomputeFilteredEntries(from: nextEntries)
    }

    private func refreshFromLogger() {
        let latestEntries = Self.trimmedEntries(AppLogger.entries)
        pendingLiveEntries.removeAll(keepingCapacity: true)
        entries = latestEntries
        recomputeFilteredEntries(from: latestEntries)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if AppLogger.isSensitiveMode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text("Sensitive Mode is on. Logs show sanitized audit metadata only; task history is governed separately.")
                    Spacer()
                }
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if let diagnosticsMessage {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                    Text(diagnosticsMessage)
                        .lineLimit(2)
                    Spacer()
                    if let diagnosticsReportURL {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([diagnosticsReportURL])
                        }
                    }
                    Button {
                        self.diagnosticsMessage = nil
                        self.diagnosticsReportURL = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Log entries
            if filteredEntries.isEmpty {
                ContentUnavailableView("No Log Entries", systemImage: "doc.text",
                    description: Text(selectedLevel != nil || selectedCategory != nil || !searchText.isEmpty
                        ? "No entries match current filters."
                        : "Log entries will appear here as the app runs."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(filteredEntries) { entry in
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: filteredEntries.count) {
                        if autoScroll, let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
        .onAppear {
            refreshFromLogger()
        }
        .onChange(of: searchText) {
            flushPendingLiveEntries()
            recomputeFilteredEntries()
        }
        .onChange(of: selectedLevel) {
            flushPendingLiveEntries()
            recomputeFilteredEntries()
        }
        .onChange(of: selectedCategory) {
            flushPendingLiveEntries()
            recomputeFilteredEntries()
        }
        .onChange(of: filterTaskID) {
            flushPendingLiveEntries()
            recomputeFilteredEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLoggerDidAppendEntry)) { notification in
            guard let entry = notification.userInfo?["entry"] as? LogEntry else { return }
            DispatchQueue.main.async {
                pendingLiveEntries.append(entry)
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            flushPendingLiveEntries()
        }
        .onDisappear {
            flushPendingLiveEntries()
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(Optional(level))
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("Filter by minimum log level")

                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(Optional<String>.none)
                    ForEach(categories, id: \.self) { cat in
                        Text(cat).tag(Optional(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 138)
                .help("Filter by log category")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Stanford.ui(12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 140, maxWidth: .infinity)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("\(filteredEntries.count) entries")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 68, alignment: .trailing)

                Button {
                    let latestEntries = AppLogger.entries
                    entries = latestEntries
                    recomputeFilteredEntries(from: latestEntries)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLogger.mainLogFile.deletingLastPathComponent().path)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Open log folder in Finder")
            }

            HStack(spacing: 10) {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()

                Text("Diagnostics")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Diagnostics scope", selection: $diagnosticsScopeRawValue) {
                    ForEach(LogDiagnosticsScope.allCases) { scope in
                        Text(scope.label).tag(scope.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
                .help("Choose how far back diagnostics should analyze")

                Button {
                    generateDiagnosticsReport()
                } label: {
                    if isGeneratingDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.borderless)
                .help("Generate a sanitized developer diagnostics report")
                .disabled(isGeneratingDiagnostics)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func generateDiagnosticsReport() {
        isGeneratingDiagnostics = true
        let generatedAt = Date()
        let scope = LogDiagnosticsScope(rawValue: diagnosticsScopeRawValue) ?? .sinceLastReport
        let latestEntries = Self.trimmedEntries(AppLogger.entries)
        pendingLiveEntries.removeAll(keepingCapacity: true)
        entries = latestEntries
        recomputeFilteredEntries(from: latestEntries)

        do {
            let reportEntries = LogDiagnosticsService.collectCurrentEntries(inMemoryEntries: latestEntries)
            let history = LogDiagnosticsService.loadHistory()
            let report = LogDiagnosticsService.makeReport(
                entries: reportEntries,
                generatedAt: generatedAt,
                scope: scope,
                history: history
            )
            let url = try LogDiagnosticsService.writeReport(report)
            LogDiagnosticsService.saveHistory(from: report)
            diagnosticsReportURL = url
            if report.issueCount == 0 {
                diagnosticsMessage = report.notices.isEmpty
                    ? "Diagnostics report saved. No issue signals were detected for \(scope.label.lowercased())."
                    : "Diagnostics report saved. No actionable issues were detected for \(scope.label.lowercased()); \(report.notices.count) recovery event\(report.notices.count == 1 ? "" : "s") noted."
            } else {
                diagnosticsMessage = "Diagnostics report saved with \(report.issueCount) issue group\(report.issueCount == 1 ? "" : "s") for \(scope.label.lowercased())."
            }
            AppLogger.audit(.diagnosticsGenerated, category: "Diagnostics", fields: [
                "entries": String(report.entryCount),
                "issues": String(report.issueCount),
                "notices": String(report.notices.count),
                "errors": String(report.errorCount),
                "warnings": String(report.warningCount),
                "scope": scope.rawValue,
                "previous_report": history.lastGeneratedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
                "report": url.path
            ], level: .info)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            diagnosticsReportURL = nil
            diagnosticsMessage = "Diagnostics report failed: \(LogSanitizer.sanitize(error.localizedDescription))"
            AppLogger.audit(.diagnosticsGenerationFailed, category: "Diagnostics", fields: [
                "error": error.localizedDescription
            ], level: .error)
        }

        isGeneratingDiagnostics = false
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.logLevel {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return Stanford.poppy
        case .error: return Stanford.cardinalRed
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(Stanford.ui(12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 85, alignment: .leading)

            // Level badge
            Text(entry.level.uppercased())
                .font(Stanford.ui(11, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 52, alignment: .leading)

            // Category
            Text(entry.category)
                .font(Stanford.ui(12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            // Task ID (short)
            if let tid = entry.taskID {
                Text(String(tid.uuidString.prefix(8)))
                    .font(Stanford.ui(11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
            } else {
                Text("")
                    .frame(width: 60, alignment: .leading)
            }

            // Message
            Text(entry.message)
                .font(Stanford.ui(13, design: .monospaced))
                .foregroundStyle(levelColor == .secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(entry.logLevel == .error ? Stanford.cardinalRed.opacity(0.06) :
                     entry.logLevel == .warning ? Stanford.poppy.opacity(0.04) : .clear)
    }
}
