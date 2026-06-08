import SwiftUI
import ASTRACore

private enum TaskDetailFilePathMatcher {
    static let regex = try? NSRegularExpression(pattern: #"(?:/[\w.@\-]+){2,}(?:\.\w+)?"#)
}

struct TaskDetailView: View {
    let task: AgentTask
    var onRunTask: ((AgentTask) -> Void)?
    var onCancelTask: ((AgentTask) -> Void)?
    var onRetryTask: ((AgentTask) -> Void)?
    var onApproveTask: ((AgentTask) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab = "timeline"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(task.title)
                        .font(Stanford.heading(20))
                        .foregroundStyle(Stanford.black)

                    Spacer()

                    // Action buttons based on status
                    actionButtons

                    if task.status != .running {
                        Button {
                            withAnimation(reduceMotion ? nil : .default) {
                                task.isDone.toggle()
                                task.updatedAt = Date()
                                try? modelContext.save()
                            }
                        } label: {
                            Text(task.isDone ? "Reopen" : "Close")
                                .font(Stanford.body(15).weight(.medium))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(task.isDone ? Stanford.cardBackground : Stanford.paloAltoGreen)
                                .foregroundStyle(task.isDone ? Stanford.black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(task.isDone ? Color.secondary.opacity(0.25) : .clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    StatusBadge(status: task.status)
                }

                HStack(spacing: 16) {
                    Label(task.resolvedRuntimeID.displayName, systemImage: "server.rack")
                        .font(Stanford.caption())
                        .foregroundStyle(Stanford.coolGrey)

                    Label(task.model, systemImage: "cpu")
                        .font(Stanford.caption())
                        .foregroundStyle(Stanford.coolGrey)

                    Label(task.workspace?.name ?? "No workspace", systemImage: "folder")
                        .font(Stanford.caption())
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(1)

                    if task.costUSD > 0 {
                        Label(String(format: "$%.2f", task.costUSD), systemImage: "dollarsign.circle")
                            .font(Stanford.caption())
                            .foregroundStyle(Stanford.coolGrey)
                    }
                }

                // Token budget bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tokens: \(Formatters.formatTokens(task.tokensUsed)) / \(Formatters.formatTokens(task.tokenBudget))")
                            .font(Stanford.caption())
                            .foregroundStyle(Stanford.coolGrey)
                        Spacer()
                        Text("\(Int(task.budgetProgress * 100))%")
                            .font(Stanford.caption())
                            .foregroundStyle(Stanford.coolGrey)
                    }
                    ProgressView(value: task.budgetProgress)
                        .tint(task.budgetProgress > 0.9 ? Stanford.failed : task.budgetProgress > 0.7 ? Stanford.poppy : Stanford.lagunita)
                }
            }
            .padding()

            Divider()

            // Tab bar
            Picker("View", selection: $selectedTab) {
                Text("Timeline").tag("timeline")
                Text("Output").tag("output")
                Text("Diffs").tag("diffs")
                Text("Artifacts").tag("artifacts")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Tab content
            switch selectedTab {
            case "timeline":
                TimelineTabView(task: task)
            case "output":
                OutputTabView(task: task)
            case "diffs":
                DiffsTabView(task: task)
            case "artifacts":
                ArtifactsTabView(task: task)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch task.status {
        case .queued:
            if let onRun = onRunTask {
                Button("Run") { onRun(task) }
                    .buttonStyle(StanfordButtonStyle())
                    .accessibilityIdentifier("RunTaskButton")
            }

        case .running:
            if let onCancel = onCancelTask {
                Button("Cancel") { onCancel(task) }
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                    .accessibilityIdentifier("CancelTaskButton")
            }

        case .pendingUser:
            HStack(spacing: 8) {
                if let onApprove = onApproveTask {
                    Button("Approve") { onApprove(task) }
                        .buttonStyle(StanfordButtonStyle())
                        .accessibilityIdentifier("ApproveTaskButton")
                }
                if let onRetry = onRetryTask {
                    Button("Retry") { onRetry(task) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: false))
                }
            }

        case .failed, .budgetExceeded:
            if let onRetry = onRetryTask {
                Button("Retry") { onRetry(task) }
                    .buttonStyle(StanfordButtonStyle())
            }

        case .completed, .cancelled, .draft:
            EmptyView()
        }
    }

}

struct StatusBadge: View {
    let status: TaskStatus

    var color: Color {
        switch status {
        case .draft: return Stanford.driftwood
        case .queued: return Stanford.queued
        case .running: return Stanford.running
        case .pendingUser: return Stanford.pendingUser
        case .completed: return Stanford.completed
        case .failed, .budgetExceeded: return Stanford.failed
        case .cancelled: return Stanford.cancelled
        }
    }

    var body: some View {
        Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(Stanford.caption(12))
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct TimelineTabView: View {
    let task: AgentTask
    @State private var sortedEvents: [TaskEvent] = []

    private func rebuildSortedEvents() {
        sortedEvents = task.events.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        Group {
            if sortedEvents.isEmpty {
                ContentUnavailableView("No Events", systemImage: "clock", description: Text("Events will appear here when the task runs."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sortedEvents) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: eventIcon(event.type))
                                        .foregroundStyle(eventColor(event.type))
                                        .font(Stanford.ui(13))
                                        .frame(width: 16)
                                        .padding(.top, 3)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(eventLabel(event.type))
                                            .font(Stanford.caption(12))
                                            .fontWeight(.medium)
                                            .foregroundStyle(.secondary)

                                        Text(event.payload)
                                            .font(Stanford.body(15))
                                            .textSelection(.enabled)

                                        Text(event.timestamp, style: .time)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .id(event.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: sortedEvents.count) {
                        if let last = sortedEvents.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { rebuildSortedEvents() }
        .onChange(of: task.events.count) { rebuildSortedEvents() }
    }

    private func eventIcon(_ type: String) -> String {
        switch type {
        case "task.started": return "play.circle"
        case "agent.thinking": return "brain"
        case "agent.response": return "text.bubble"
        case "tool.use": return "wrench"
        case "astra.todo.replace": return "checklist"
        case "astra.complete": return "checkmark.seal"
        case "astra.protocol.invalid": return "exclamationmark.triangle"
        case "task.completed": return "checkmark.circle"
        case "task.stats": return "chart.bar"
        case "budget.exceeded": return "exclamationmark.triangle"
        case "budget.warning": return "exclamationmark.triangle"
        case "error": return "xmark.circle"
        case "user.message": return "person.circle"
        default: return "circle"
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "task.started": return Stanford.lagunita
        case "agent.thinking": return Stanford.driftwood
        case "agent.response": return Stanford.black
        case "tool.use": return Stanford.poppy
        case "astra.todo.replace": return Stanford.lagunita
        case "astra.complete": return Stanford.paloAltoGreen
        case "astra.protocol.invalid": return Stanford.poppy
        case "task.completed": return Stanford.paloAltoGreen
        case "task.stats": return Stanford.sky
        case "budget.exceeded": return Stanford.failed
        case "budget.warning": return Stanford.poppy
        case "error": return Stanford.failed
        case "user.message": return Stanford.bay
        default: return Stanford.coolGrey
        }
    }

    private func eventLabel(_ type: String) -> String {
        switch type {
        case "task.started": return "Started"
        case "agent.thinking": return "Thinking"
        case "agent.response": return "Response"
        case "tool.use": return "Tool"
        case "astra.todo.replace": return "Agent Plan"
        case "astra.complete": return "Agent Completion"
        case "astra.protocol.invalid": return "Invalid Protocol"
        case "task.completed": return "Completed"
        case "task.stats": return "Stats"
        case "budget.exceeded": return "Budget Exceeded"
        case "budget.warning": return "Budget Warning"
        case "error": return "Error"
        case "user.message": return "You"
        default: return type
        }
    }
}

struct OutputTabView: View {
    let task: AgentTask
    @State private var latestRun: TaskRun?

    private func rebuildLatestRun() {
        latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    var body: some View {
        Group {
            if let run = latestRun, !run.output.isEmpty {
                ScrollView {
                    Text(run.output)
                        .font(Stanford.ui(15, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView("No Output", systemImage: "terminal", description: Text("Output will appear here when the task runs."))
            }
        }
        .onAppear { rebuildLatestRun() }
        .onChange(of: task.runs.count) { rebuildLatestRun() }
    }
}

struct ArtifactsTabView: View {
    let task: AgentTask
    @State private var taskFolderFiles: [ArtifactFile] = []
    @State private var cachedAllFiles: [ArtifactFile] = []

    struct ArtifactFile: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64
        let source: String // "changed", "created", "output"

        func hash(into hasher: inout Hasher) { hasher.combine(path) }
        static func == (lhs: ArtifactFile, rhs: ArtifactFile) -> Bool { lhs.path == rhs.path }
    }

    @State private var latestRun: TaskRun?

    private func rebuildLatestRun() {
        latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    @State private var allFilesRefreshTask: Task<Void, Never>?

    /// Recompute cachedAllFiles off the main render path. Called from
    /// onAppear/onChange. The per-file `fileExists`/`attributesOfItem` stats run
    /// on a detached task (mirroring `scanTaskFolder`) so they never block the
    /// main actor — the prior implementation did the syscalls synchronously
    /// despite this comment. See the UI responsiveness audit (Cluster 2).
    private func refreshAllFiles() {
        let runFileChanges = latestRun?.fileChanges ?? []
        let folderFiles = taskFolderFiles
        let inputs = task.inputs
        let outputFiles = outputPathFiles

        // onAppear + several onChange triggers can fire in quick succession.
        // Cancel the in-flight refresh and skip a stale apply so an earlier
        // task can't finish last and overwrite cachedAllFiles with old data.
        allFilesRefreshTask?.cancel()
        allFilesRefreshTask = Task {
            let files: [ArtifactFile] = await Task.detached(priority: .userInitiated) {
                var files: [ArtifactFile] = []
                var seen = Set<String>()
                let fm = FileManager.default

                // 1. Files from fileChanges (written/edited by agent)
                for change in runFileChanges {
                    guard !seen.contains(change.path) else { continue }
                    seen.insert(change.path)
                    let exists = fm.fileExists(atPath: change.path)
                    files.append(ArtifactFile(
                        path: change.path,
                        name: URL(fileURLWithPath: change.path).lastPathComponent,
                        isDirectory: false,
                        size: exists ? (try? fm.attributesOfItem(atPath: change.path)[.size] as? Int64) ?? 0 : 0,
                        source: change.kind == .write ? "created" : "changed"
                    ))
                }

                // 2. Files in task output folder
                for file in folderFiles where seen.insert(file.path).inserted {
                    files.append(file)
                }

                // 3. Attached input files
                for input in inputs where !input.isEmpty {
                    guard seen.insert(input).inserted else { continue }
                    var isDir: ObjCBool = false
                    let exists = fm.fileExists(atPath: input, isDirectory: &isDir)
                    files.append(ArtifactFile(
                        path: input,
                        name: URL(fileURLWithPath: input).lastPathComponent,
                        isDirectory: isDir.boolValue,
                        size: exists && !isDir.boolValue ? ((try? fm.attributesOfItem(atPath: input)[.size] as? Int64) ?? 0) : 0,
                        source: "input"
                    ))
                }

                // 4. File paths found in output text (for imported sessions)
                for file in outputFiles where seen.insert(file.path).inserted {
                    files.append(file)
                }

                return files
            }.value

            guard !Task.isCancelled else { return }
            cachedAllFiles = files
        }
    }

    @State private var outputPathFiles: [ArtifactFile] = []

    var body: some View {
        VStack(spacing: 0) {
            if cachedAllFiles.isEmpty {
                ContentUnavailableView("No Artifacts", systemImage: "doc",
                    description: Text("Artifacts will appear here when the task produces files."))
            } else {
                // Header
                HStack {
                    Text("\(cachedAllFiles.count) file\(cachedAllFiles.count == 1 ? "" : "s")")
                        .font(Stanford.caption(13))
                        .foregroundStyle(Stanford.coolGrey)
                    Spacer()
                    if !TaskWorkspaceAccess(task: task).taskFolder.isEmpty {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder))
                        } label: {
                            Label("Open Folder", systemImage: "folder")
                                .font(Stanford.caption(12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.lagunita)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // File list
                List(cachedAllFiles) { file in
                    Button {
                        let url = URL(fileURLWithPath: file.path)
                        if file.isDirectory {
                            NSWorkspace.shared.open(url)
                        } else if FileManager.default.fileExists(atPath: file.path) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: fileIcon(for: file))
                                .font(Stanford.ui(16))
                                .foregroundStyle(fileColor(for: file))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(Stanford.body(14))
                                    .foregroundStyle(Stanford.black)
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(Stanford.coolGrey)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            // Source badge
                            Text(file.source)
                                .font(Stanford.caption(11))
                                .foregroundStyle(badgeColor(for: file.source))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeColor(for: file.source).opacity(0.1))
                                .clipShape(Capsule())

                            if file.size > 0 {
                                Text(formatSize(file.size))
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(Stanford.coolGrey)
                            }

                            // File exists indicator
                            if FileManager.default.fileExists(atPath: file.path) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(Stanford.ui(12))
                                    .foregroundStyle(Stanford.lagunita)
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(Stanford.ui(12))
                                    .foregroundStyle(Stanford.poppy)
                                    .help("File no longer exists at this path")
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }
                        if FileManager.default.fileExists(atPath: file.path) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                            } label: {
                                Label("Open", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            rebuildLatestRun()
            scanTaskFolder()
            extractPathsFromOutput()
            refreshAllFiles()
        }
        .onChange(of: task.runs.count) {
            rebuildLatestRun()
            extractPathsFromOutput()
            refreshAllFiles()
        }
        .onChange(of: taskFolderFiles.count) {
            refreshAllFiles()
        }
        .onChange(of: outputPathFiles.count) {
            refreshAllFiles()
        }
    }

    // MARK: - Helpers

    private func scanTaskFolder() {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        Task {
            let scanned: [ArtifactFile] = await Task.detached(priority: .userInitiated) {
                guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { return [] }
                guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return [] }

                var files: [ArtifactFile] = []
                while let relativePath = enumerator.nextObject() as? String {
                    let fullPath = (folder as NSString).appendingPathComponent(relativePath)
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                    if isDir.boolValue { continue }
                    let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int64) ?? 0
                    files.append(ArtifactFile(path: fullPath, name: URL(fileURLWithPath: fullPath).lastPathComponent, isDirectory: false, size: size, source: "output"))
                }
                return files
            }.value
            taskFolderFiles = scanned
        }
    }

    /// Extract file paths from run output and event payloads
    private func extractPathsFromOutput() {
        var texts: [String] = []
        if let run = latestRun { texts.append(run.output) }
        for event in task.events where ["tool.use", "agent.response"].contains(event.type) {
            texts.append(event.payload)
        }
        let combined = texts.joined(separator: "\n")
        guard !combined.isEmpty else { return }
        Task {
            let found: [ArtifactFile] = await Task.detached(priority: .userInitiated) {
                guard let regex = TaskDetailFilePathMatcher.regex else { return [] }
                let nsText = combined as NSString
                let matches = regex.matches(in: combined, range: NSRange(location: 0, length: nsText.length))
                var seen = Set<String>()
                var files: [ArtifactFile] = []
                let fm = FileManager.default
                for match in matches {
                    let path = nsText.substring(with: match.range)
                    guard !seen.contains(path) else { continue }
                    seen.insert(path)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                    if path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") ||
                       path.hasPrefix("/System/") || path.hasPrefix("/Library/") ||
                       path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/private/") { continue }
                    if path.contains("/.claude/") { continue }
                    let size: Int64 = isDir.boolValue ? 0 : ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
                    files.append(ArtifactFile(path: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: isDir.boolValue, size: size, source: isDir.boolValue ? "folder" : "referenced"))
                }
                return files
            }.value
            outputPathFiles = found
        }
    }

    private func fileIcon(for file: ArtifactFile) -> String {
        if file.isDirectory { return "folder.fill" }
        let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
        switch ext {
        case "swift", "py", "js", "ts", "go", "rs", "java", "kt", "c", "cpp", "h", "m":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "md", "markdown", "qmd", "txt", "rtf", "log":
            return "doc.plaintext"
        case "html", "htm", "css":
            return "globe"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz":
            return "doc.zipper"
        default:
            return "doc"
        }
    }

    private func fileColor(for file: ArtifactFile) -> Color {
        switch file.source {
        case "created": return Stanford.paloAltoGreen
        case "changed": return Stanford.poppy
        case "input": return Stanford.cardinalRed
        case "folder": return Stanford.driftwood
        case "referenced": return Stanford.sky
        default: return Stanford.lagunita
        }
    }

    private func badgeColor(for source: String) -> Color {
        switch source {
        case "created": return Stanford.paloAltoGreen
        case "changed": return Stanford.poppy
        case "input": return Stanford.cardinalRed
        case "folder": return Stanford.driftwood
        case "referenced": return Stanford.sky
        default: return Stanford.lagunita
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

struct DiffsTabView: View {
    let task: AgentTask
    @State private var selectedChange: StoredFileChange?
    @State private var latestRun: TaskRun?

    private func rebuildLatestRun() {
        latestRun = task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    var changes: [StoredFileChange] {
        latestRun?.fileChanges ?? []
    }

    var body: some View {
        Group {
        if changes.isEmpty {
            ContentUnavailableView("No File Changes", systemImage: "doc.text.magnifyingglass",
                                   description: Text("File changes will appear here when the agent writes or edits files."))
        } else {
            HSplitView {
                // File list
                List(changes, selection: $selectedChange) { change in
                    HStack {
                        Image(systemName: change.kind == .write ? "doc.badge.plus" : "pencil")
                            .foregroundStyle(change.kind == .write ? Stanford.paloAltoGreen : Stanford.poppy)
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: change.path).lastPathComponent)
                                .font(Stanford.body(15))
                            Text(change.path)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .tag(change)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedChange = change }
                }
                .frame(minWidth: 180, maxWidth: 250)

                // Diff detail
                if let change = selectedChange {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(change.changeType, systemImage: change.kind == .write ? "doc.badge.plus" : "pencil")
                                    .font(Stanford.ui(15, weight: .semibold))
                                Spacer()
                                Text(change.timestamp, style: .time)
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }

                            Text(change.path)
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)

                            if change.kind == .write {
                                if let content = change.content {
                                    Text("New file content:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(.secondary)
                                    Text(content)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffAdded.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            } else {
                                if let oldStr = change.oldString {
                                    Text("Removed:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(Stanford.diffRemoved)
                                    Text(oldStr)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffRemoved.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                if let newStr = change.newString {
                                    Text("Added:")
                                        .font(Stanford.caption(12))
                                        .foregroundStyle(Stanford.diffAdded)
                                    Text(newStr)
                                        .font(Stanford.ui(12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Stanford.diffAdded.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text",
                                           description: Text("Select a file from the list to view changes."))
                }
            }
        }
        } // Group
        .onAppear { rebuildLatestRun() }
        .onChange(of: task.runs.count) { rebuildLatestRun() }
    }
}
