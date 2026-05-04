import SwiftUI

struct LogViewerView: View {
    @State private var entries: [LogEntry] = AppLogger.entries
    @State private var filteredEntries: [LogEntry] = []
    @State private var searchText = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var selectedCategory: String? = nil
    @State private var autoScroll = true
    @State private var filterTaskID: UUID? = nil

    private let categories = [
        "App", "Audit", "Worker", "Queue", "UI", "Isolation", "Validation",
        "Reflection", "SSH", "Persistence", "PluginCatalog", "Scheduler",
        "Keychain", "Updater", "Performance", "General"
    ]

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
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Level filter
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(Optional(level))
                    }
                }
                .frame(width: 130)

                // Category filter
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(Optional<String>.none)
                    ForEach(categories, id: \.self) { cat in
                        Text(cat).tag(Optional(cat))
                    }
                }
                .frame(width: 150)

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()

                // Entry count
                Text("\(filteredEntries.count) entries")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Button {
                    let latestEntries = AppLogger.entries
                    entries = latestEntries
                    recomputeFilteredEntries(from: latestEntries)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLogger.mainLogFile.deletingLastPathComponent().path)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open log folder in Finder")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

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
            let latestEntries = AppLogger.entries
            entries = latestEntries
            recomputeFilteredEntries(from: latestEntries)
        }
        .onChange(of: searchText) { recomputeFilteredEntries() }
        .onChange(of: selectedLevel) { recomputeFilteredEntries() }
        .onChange(of: selectedCategory) { recomputeFilteredEntries() }
        .onChange(of: filterTaskID) { recomputeFilteredEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .appLoggerDidAppendEntry)) { notification in
            guard let entry = notification.userInfo?["entry"] as? LogEntry else { return }
            DispatchQueue.main.async {
                entries.append(entry)
                if entries.count > 2000 {
                    entries.removeFirst(entries.count - 2000)
                }
                recomputeFilteredEntries()
            }
        }
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
