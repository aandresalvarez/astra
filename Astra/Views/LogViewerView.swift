import SwiftUI
import AppKit

struct LogViewerView: View {
    private static let maxVisibleEntries = 2000

    private enum DiagnosticsDelivery {
        case archive
        case file
        case clipboard
    }

    @Environment(\.dismiss) private var dismiss
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
    @AppStorage(AppStorageKeys.runtimeStreamDebugCapture) private var runtimeStreamDebugCapture = LoggingPreferences.defaultRuntimeStreamDebugCapture
    @AppStorage(AppStorageKeys.browserDebugCapture) private var browserDebugCapture = LoggingPreferences.defaultBrowserDebugCapture

    private var hasActiveFilters: Bool {
        selectedLevel != nil ||
            selectedCategory != nil ||
            filterTaskID != nil ||
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleEntrySummary: String {
        if filteredEntries.count == entries.count {
            return "\(filteredEntries.count) entries"
        }
        return "\(filteredEntries.count) of \(entries.count)"
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
            header
            controls
            notices
            logTable
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshFromLogger()
        }
        .onExitCommand {
            dismiss()
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.sky)
                .frame(width: 34, height: 34)
                .background(Stanford.sky.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Logs")
                    .font(Stanford.heading(22))
                Text("Live sanitized audit stream and diagnostics")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                refreshFromLogger()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Refresh logs")

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLogger.mainLogFile.deletingLastPathComponent().path)
            } label: {
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Open log folder in Finder")

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("Close logs")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField

                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(Optional(level))
                    }
                }
                .labelsHidden()
                .frame(width: 126)
                .help("Filter by minimum log level")

                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(Optional<String>.none)
                    ForEach(AppLogCategory.all, id: \.self) { cat in
                        Text(cat).tag(Optional(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Filter by log category")

                if hasActiveFilters {
                    Button {
                        clearFilters()
                    } label: {
                        Label("Clear", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear filters")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(autoScroll ? Color.secondary : Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Toggle("Auto-scroll", isOn: $autoScroll)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .fixedSize()
                    }

                    Divider()
                        .frame(height: 18)

                    Picker("Diagnostics scope", selection: $diagnosticsScopeRawValue) {
                        ForEach(LogDiagnosticsScope.allCases) { scope in
                            Text(scope.label).tag(scope.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 176)
                    .help("Choose how far back diagnostics should analyze")

                    Spacer(minLength: 0)

                    Text(visibleEntrySummary)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Button {
                        generateDiagnosticsReport(delivery: .archive)
                    } label: {
                        Label("Download bundle", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Create a diagnostics zip for the selected time window")
                    .disabled(isGeneratingDiagnostics)

                    Button {
                        generateDiagnosticsReport(delivery: .file)
                    } label: {
                        if isGeneratingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Save report", systemImage: "stethoscope")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Generate a sanitized developer diagnostics report")
                    .disabled(isGeneratingDiagnostics)

                    Button {
                        generateDiagnosticsReport(delivery: .clipboard)
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the diagnostics report markdown to the clipboard")
                    .disabled(isGeneratingDiagnostics)

                    Button {
                        revealCrashReports()
                    } label: {
                        Label("Crash/Hang", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal recent ASTRA crash or hang reports in Finder")
                    .disabled(isGeneratingDiagnostics)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search logs", text: $searchText)
                .textFieldStyle(.plain)
                .font(Stanford.ui(13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 220, maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private var notices: some View {
        VStack(spacing: 8) {
            if AppLogger.isSensitiveMode {
                inlineNotice(
                    icon: "lock.shield",
                    tint: Stanford.paloAltoGreen,
                    message: "Sensitive Mode is on. Logs show sanitized audit metadata only; task history is governed separately."
                )
            }

            if browserDebugCapture {
                inlineNotice(
                    icon: "camera.metering.matrix",
                    tint: Stanford.poppy,
                    message: "Browser Debug Capture is on. Failed browser actions may write screenshot thumbnails and compact page evidence to browser-flight JSONL logs."
                )
            }

            if runtimeStreamDebugCapture {
                inlineNotice(
                    icon: "waveform.path.ecg",
                    tint: Stanford.sky,
                    message: "Runtime Stream Debug Logging is on. Provider runs retain bounded raw-line samples, unknown JSON shapes, and stderr tails in task logs."
                )
            }

            if let diagnosticsMessage {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(Stanford.sky)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Stanford.sky.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func inlineNotice(icon: String, tint: Color, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
            Spacer(minLength: 0)
        }
        .font(Stanford.caption(12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
    }

    private var logTable: some View {
        VStack(spacing: 0) {
            logTableHeader
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredEntries) { entry in
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var logTableHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Time")
                .frame(width: 92, alignment: .leading)
            Text("Level")
                .frame(width: 58, alignment: .leading)
            Text("Category")
                .frame(width: 96, alignment: .leading)
            Text("Task")
                .frame(width: 70, alignment: .leading)
            Text("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Stanford.caption(11).weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Log Entries",
            systemImage: "doc.text",
            description: Text(hasActiveFilters
                ? "No entries match the current filters."
                : "Log entries will appear here as the app runs.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 42)
    }

    private func clearFilters() {
        selectedLevel = nil
        selectedCategory = nil
        filterTaskID = nil
        searchText = ""
    }

    private func generateDiagnosticsReport(delivery: DiagnosticsDelivery) {
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
            let analysisInterval = LogDiagnosticsService.analysisDateInterval(
                scope: scope,
                generatedAt: generatedAt,
                previousGeneratedAt: history.lastGeneratedAt
            )
            let crashReports = CrashDiagnosticsService.reports(
                limit: 50,
                modifiedIn: analysisInterval
            )
            let report = LogDiagnosticsService.makeReport(
                entries: reportEntries,
                generatedAt: generatedAt,
                scope: scope,
                history: history,
                crashReports: crashReports
            )
            let analyzedEntries = LogDiagnosticsService.analyzedEntries(
                reportEntries,
                generatedAt: generatedAt,
                scope: scope,
                history: history
            )

            switch delivery {
            case .archive:
                let archive = try LogDiagnosticsService.writeArchive(
                    report: report,
                    analyzedEntries: analyzedEntries,
                    analysisInterval: analysisInterval,
                    crashReports: crashReports
                )
                diagnosticsReportURL = archive.url
                diagnosticsMessage = diagnosticsArchiveSuccessMessage(
                    report: report,
                    scope: scope,
                    archive: archive
                )
                AppLogger.audit(.diagnosticsGenerated, category: "Diagnostics", fields: [
                    "entries": String(report.entryCount),
                    "issues": String(report.issueCount),
                    "notices": String(report.notices.count),
                    "errors": String(report.errorCount),
                    "warnings": String(report.warningCount),
                    "crash_reports": String(report.crashReports.count),
                    "scope": scope.rawValue,
                    "delivery": "archive",
                    "artifacts": String(archive.artifactCount),
                    "previous_report": history.lastGeneratedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
                    "archive": archive.url.path
                ], level: .info)
                LogDiagnosticsService.saveHistory(from: report)
                NSWorkspace.shared.activateFileViewerSelecting([archive.url])
            case .file:
                let url = try LogDiagnosticsService.writeReport(report)
                diagnosticsReportURL = url
                diagnosticsMessage = diagnosticsSuccessMessage(
                    report: report,
                    scope: scope,
                    verb: "saved"
                )
                AppLogger.audit(.diagnosticsGenerated, category: "Diagnostics", fields: [
                    "entries": String(report.entryCount),
                    "issues": String(report.issueCount),
                    "notices": String(report.notices.count),
                    "errors": String(report.errorCount),
                    "warnings": String(report.warningCount),
                    "crash_reports": String(report.crashReports.count),
                    "scope": scope.rawValue,
                    "delivery": "file",
                    "previous_report": history.lastGeneratedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
                    "report": url.path
                ], level: .info)
                LogDiagnosticsService.saveHistory(from: report)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .clipboard:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.markdown, forType: .string)
                diagnosticsReportURL = nil
                diagnosticsMessage = diagnosticsSuccessMessage(
                    report: report,
                    scope: scope,
                    verb: "copied to clipboard"
                )
                AppLogger.audit(.diagnosticsGenerated, category: "Diagnostics", fields: [
                    "entries": String(report.entryCount),
                    "issues": String(report.issueCount),
                    "notices": String(report.notices.count),
                    "errors": String(report.errorCount),
                    "warnings": String(report.warningCount),
                    "crash_reports": String(report.crashReports.count),
                    "scope": scope.rawValue,
                    "delivery": "clipboard",
                    "previous_report": history.lastGeneratedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                ], level: .info)
                LogDiagnosticsService.saveHistory(from: report)
            }
        } catch {
            diagnosticsReportURL = nil
            diagnosticsMessage = "Diagnostics report failed: \(LogSanitizer.sanitize(error.localizedDescription))"
            AppLogger.audit(.diagnosticsGenerationFailed, category: "Diagnostics", fields: [
                "error": error.localizedDescription
            ], level: .error)
        }

        isGeneratingDiagnostics = false
    }

    private func revealCrashReports() {
        let reports = CrashDiagnosticsService.recentReports(limit: 20, withinDays: nil)
        if reports.isEmpty {
            let directory = CrashDiagnosticsService.defaultDiagnosticReportsDirectory
            if FileManager.default.fileExists(atPath: directory.path) {
                NSWorkspace.shared.open(directory)
                diagnosticsMessage = "No ASTRA crash or hang reports found. Opened macOS DiagnosticReports."
            } else {
                diagnosticsMessage = "No ASTRA crash or hang reports found, and macOS has not created a DiagnosticReports folder yet."
            }
            AppLogger.audit(.crashReportsRevealed, category: "Diagnostics", fields: [
                "count": "0",
                "directory": CrashDiagnosticsService.userFacingPath(directory)
            ], level: .info)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(reports.map(\.url))
        diagnosticsMessage = "Revealed \(reports.count) recent ASTRA crash/hang report\(reports.count == 1 ? "" : "s") in Finder."
        AppLogger.audit(.crashReportsRevealed, category: "Diagnostics", fields: [
            "count": String(reports.count),
            "latest": reports.first?.fileName ?? "none",
            "directory": CrashDiagnosticsService.userFacingPath(CrashDiagnosticsService.defaultDiagnosticReportsDirectory)
        ], level: .info)
    }

    private func diagnosticsSuccessMessage(
        report: LogDiagnosticsReport,
        scope: LogDiagnosticsScope,
        verb: String
    ) -> String {
        if report.issueCount == 0 {
            if report.notices.isEmpty {
                return "Diagnostics report \(verb). No issue signals were detected for \(scope.label.lowercased())."
            }
            return "Diagnostics report \(verb). No actionable issues were detected for \(scope.label.lowercased()); \(report.notices.count) recovery event\(report.notices.count == 1 ? "" : "s") noted."
        }
        return "Diagnostics report \(verb) with \(report.issueCount) issue group\(report.issueCount == 1 ? "" : "s") for \(scope.label.lowercased())."
    }

    private func diagnosticsArchiveSuccessMessage(
        report: LogDiagnosticsReport,
        scope: LogDiagnosticsScope,
        archive: LogDiagnosticsArchiveResult
    ) -> String {
        let crashText = archive.crashReportCount == 0
            ? "no crash/hang reports"
            : "\(archive.crashReportCount) crash/hang report\(archive.crashReportCount == 1 ? "" : "s")"
        if report.issueCount == 0 {
            return "Diagnostics bundle saved with \(archive.artifactCount) artifact\(archive.artifactCount == 1 ? "" : "s") and \(crashText) for \(scope.label.lowercased())."
        }
        return "Diagnostics bundle saved with \(archive.artifactCount) artifact\(archive.artifactCount == 1 ? "" : "s"), \(crashText), and \(report.issueCount) issue group\(report.issueCount == 1 ? "" : "s")."
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.logLevel {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return Stanford.poppy
        case .error: return Stanford.failed
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(Stanford.ui(12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)

            Text(entry.level.uppercased())
                .font(Stanford.ui(11, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 58, alignment: .leading)

            Text(entry.category)
                .font(Stanford.ui(12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            if let tid = entry.taskID {
                Text(String(tid.uuidString.prefix(8)))
                    .font(Stanford.ui(11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .leading)
            } else {
                Text("")
                    .frame(width: 70, alignment: .leading)
            }

            Text(entry.message)
                .font(Stanford.ui(13, design: .monospaced))
                .foregroundStyle(levelColor == .secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background(entry.logLevel == .error ? Stanford.failed.opacity(0.06) :
                     entry.logLevel == .warning ? Stanford.poppy.opacity(0.04) : .clear)
    }
}
