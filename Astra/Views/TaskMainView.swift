import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum TaskMainTab: String, CaseIterable {
    case summary = "Chat"
    case files = "Files"
}

/// Unified main view: compact status bar + chat-style activity thread + composer
struct TaskMainView: View {
    let task: AgentTask
    var taskQueue: TaskQueue?
    var onRunTask: ((AgentTask) -> Void)?
    var onCancelTask: ((AgentTask) -> Void)?
    var onRetryTask: ((AgentTask) -> Void)?
    var onResumeTask: ((AgentTask) -> Void)?
    var onApproveTask: ((AgentTask) -> Void)?
    var onToggleDone: ((AgentTask) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @State private var messageText = ""
    @State private var attachedFiles: [String] = []
    @State private var slashSelectedIndex = 0
    @State private var isDragOver = false
    @State private var showDiffsSheet = false
    @State private var selectedTab: TaskMainTab = .summary
    @State private var expandedRunActivity: Set<UUID> = []
    @State private var showScheduleEditor = false
    @State private var isCreatingSchedule = false
    @State private var scheduleStatusMessage: String?
    @State private var isGeneratingRecap = false
    @State private var recapStatusMessage: String?
    @State private var showCopyConfirmation = false
    @State private var pasteMonitor: Any?
    var onMoveToDraft: ((AgentTask) -> Void)?
    var onManageSkills: (() -> Void)?
    var onForkTask: ((AgentTask) -> Void)?

    private var availableSkills: [Skill] {
        guard let workspace = task.workspace else { return [] }
        return WorkspaceCapabilities(workspace: workspace, globalSkills: globalSkills).activeSkills
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color(nsColor: .windowBackgroundColor), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(height: 18)
                    .allowsHitTesting(false)
                }

            if selectedTab != .files {
                composerView
            }
        }
        .navigationTitle(task.title)
        .navigationSubtitle(task.workspace?.name ?? "Astra")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                taskControlBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .allowsHitTesting(true)
        }
        .sheet(isPresented: $showDiffsSheet) {
            DiffsTabView(task: task)
                .frame(minWidth: 700, minHeight: 500)
        }
        .sheet(isPresented: $showScheduleEditor) {
            if let ws = task.workspace {
                ScheduleEditorView(
                    workspace: ws,
                    prefillName: task.title,
                    prefillGoal: task.goal,
                    prefillModel: task.model,
                    prefillBudget: task.tokenBudget,
                    prefillSkillIDs: Set(task.skills.map { $0.id.uuidString }),
                    prefillConversationContext: scheduleConversationContext,
                    prefillSourceTaskID: task.id
                )
            }
        }
        .onChange(of: task.id) {
            selectedTab = .summary
        }
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers == "v" {
                    if smartPaste() { return nil }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = pasteMonitor {
                NSEvent.removeMonitor(monitor)
                pasteMonitor = nil
            }
        }
    }

    // MARK: - Toolbar Stats

    private var taskIDString: String {
        task.id.uuidString.prefix(8).lowercased()
    }

    private var taskControlBar: some View {
        HStack(spacing: 10) {
            filesButton
            actionButtons
        }
        .controlSize(.small)
    }

    private var filesButton: some View {
        Button {
            selectedTab = selectedTab == .files ? .summary : .files
        } label: {
            Image(systemName: selectedTab == .files ? "doc.text.fill" : "doc.text")
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(selectedTab == .files ? Stanford.lagunita : Stanford.coolGrey)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(selectedTab == .files ? "Show chat" : "Show files")
        .accessibilityLabel(selectedTab == .files ? "Show chat" : "Show files")
    }

    @ViewBuilder
    private var toolbarStats: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.id.uuidString, forType: .string)
            showCopyConfirmation = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { showCopyConfirmation = false }
            }
        } label: {
            Text(showCopyConfirmation ? "Copied!" : taskIDString)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(showCopyConfirmation ? Stanford.paloAltoGreen : Stanford.coolGrey)
        }
        .buttonStyle(.plain)
        .help("Copy task ID: \(task.id.uuidString)")

        if task.tokensUsed > 0 {
            Label(Formatters.formatTokens(task.tokensUsed), systemImage: "number")
                .font(Stanford.caption(13))
                .foregroundStyle(Stanford.coolGrey)
        }
        if task.costUSD > 0 {
            Label(String(format: "$%.2f", task.costUSD), systemImage: "dollarsign.circle")
                .font(Stanford.caption(13))
                .foregroundStyle(Stanford.coolGrey)
        }

        if let run = latestRun, let completed = run.completedAt {
            let durationSec = Int(completed.timeIntervalSince(run.startedAt))
            Label(formatDuration(durationSec), systemImage: "clock")
                .font(Stanford.caption(13))
                .foregroundStyle(Stanford.coolGrey)
        }

        if let run = latestRun, run.inputTokens > 0 {
            contextGauge(inputTokens: run.inputTokens)
        }

        Button {
            selectedTab = selectedTab == .files ? .summary : .files
        } label: {
            Label("Files", systemImage: "doc.text")
                .font(Stanford.caption(13))
                .foregroundStyle(selectedTab == .files ? Stanford.lagunita : Stanford.coolGrey)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .summary:
            summaryContent
        case .files:
            FilesTabView(task: task)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch task.status {
            case .queued:
                if let onRun = onRunTask {
                    Button("Run") { onRun(task) }
                        .buttonStyle(StanfordButtonStyle())
                        .controlSize(.small)
                        .accessibilityIdentifier("RunTaskButton")
                        .accessibilityLabel("Run task")
                }
            case .running:
                if let onCancel = onCancelTask {
                    Button("Cancel") { onCancel(task) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: false))
                        .controlSize(.small)
                        .accessibilityIdentifier("CancelTaskButton")
                        .accessibilityLabel("Cancel task")
                }
            case .pendingUser:
                if let onApprove = onApproveTask {
                    Button("Approve") { onApprove(task) }
                        .buttonStyle(StanfordButtonStyle())
                        .controlSize(.small)
                        .accessibilityIdentifier("ApproveTaskButton")
                        .accessibilityLabel("Approve task")
                }
                if let onRetry = onRetryTask {
                    Button("Retry") { onRetry(task) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: false))
                        .controlSize(.small)
                        .accessibilityLabel("Retry task")
                }
            case .failed, .budgetExceeded:
                if task.sessionId != nil, let onResume = onResumeTask {
                    Button("Resume") { onResume(task) }
                        .buttonStyle(StanfordButtonStyle())
                        .controlSize(.small)
                        .help("Continue where the agent left off")
                        .accessibilityLabel("Resume task")
                }
                if let onRetry = onRetryTask {
                    Button("Retry") { onRetry(task) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: task.sessionId == nil))
                        .controlSize(.small)
                        .help("Start over from scratch")
                        .accessibilityLabel("Retry task")
                }
            case .completed, .cancelled, .draft:
                EmptyView()
            }

            if task.status != .running {
                Button {
                    if let onToggleDone {
                        onToggleDone(task)
                    } else {
                        withAnimation {
                            task.isDone.toggle()
                            task.updatedAt = Date()
                            try? modelContext.save()
                        }
                    }
                } label: {
                    Text(task.isDone ? "Reopen" : "Done")
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
                .controlSize(.small)
                .accessibilityLabel(task.isDone ? "Reopen task" : "Mark task as done")
            }

            if task.status != .draft {
                moreMenu
            }
        }
    }

    /// Snapshot the conversation at schedule creation time.
    /// Captures user messages and agent responses chronologically.
    private var scheduleConversationContext: String {
        var lines: [String] = []

        for item in conversationItems {
            switch item {
            case .userMessage(let text, _):
                lines.append("User: \(text)")
            case .agentResponse(let run):
                let output = String(run.output.prefix(3000))
                lines.append("Agent: \(output)")
            case .scheduleResult(let text, _):
                lines.append("Schedule: \(text)")
            case .systemInfo(let text, _):
                lines.append("System: \(text)")
            case .recapResult(let text, _):
                lines.append("Recap: \(text)")
            }
        }

        return lines.joined(separator: "\n\n")
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.id.uuidString, forType: .string)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { showCopyConfirmation = false }
                    }
                } label: {
                    Label(showCopyConfirmation ? "Copied Task ID" : "Copy Task ID", systemImage: "number")
                }

                if task.tokensUsed > 0 {
                    Label(Formatters.formatTokens(task.tokensUsed), systemImage: "number")
                }
                if task.costUSD > 0 {
                    Label(String(format: "$%.2f", task.costUSD), systemImage: "dollarsign.circle")
                }
                if let run = latestRun, let completed = run.completedAt {
                    let durationSec = Int(completed.timeIntervalSince(run.startedAt))
                    Label(formatDuration(durationSec), systemImage: "clock")
                }
                if let run = latestRun, run.inputTokens > 0 {
                    Label("\(Formatters.formatTokens(run.inputTokens))/200.0k", systemImage: "circle.dashed")
                }
            }

            Section {
                Button {
                    showScheduleEditor = true
                } label: {
                    Label("Convert to Schedule", systemImage: "clock.badge.checkmark")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("More actions")
    }

    /// Build a chronological conversation from events, runs, and the original goal.
    private var conversationItems: [ConversationItem] {
        var items: [ConversationItem] = []

        // 1. Original user goal
        items.append(.userMessage(text: task.goal, timestamp: task.createdAt))

        // 2. Collect conversation events and runs chronologically
        let conversationEvents = sortedEvents.filter {
            $0.type == "user.message" || $0.type == "agent.response" || $0.type == "schedule.result" || $0.type == "system.info" || $0.type == "recap.result"
        }
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }

        // Track which runs we've added
        var addedRunIDs = Set<UUID>()

        for event in conversationEvents {
            // Before this event, add any run output that completed
            for run in runs where !addedRunIDs.contains(run.id) {
                if let completed = run.completedAt, completed <= event.timestamp, !run.output.isEmpty {
                    items.append(.agentResponse(run: run))
                    addedRunIDs.insert(run.id)
                }
            }

            if event.type == "user.message" {
                items.append(.userMessage(text: event.payload, timestamp: event.timestamp))
            } else if event.type == "schedule.result" {
                items.append(.scheduleResult(text: event.payload, timestamp: event.timestamp))
            } else if event.type == "system.info" {
                items.append(.systemInfo(text: event.payload, timestamp: event.timestamp))
            } else if event.type == "recap.result" {
                items.append(.recapResult(text: event.payload, timestamp: event.timestamp))
            }
            // Skip agent.response events — we show the full run output instead
        }

        // 3. Add any remaining runs not yet added
        for run in runs where !addedRunIDs.contains(run.id) && !run.output.isEmpty {
            items.append(.agentResponse(run: run))
        }

        return items
    }

    private var summaryContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 10) {
                if task.isForked {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.branch")
                            .font(Stanford.ui(11))
                        Text("Forked from another task at step \(task.forkedAtRunIndex + 1)")
                            .font(Stanford.caption(12))
                    }
                    .foregroundStyle(Stanford.plum)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Stanford.plum.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 14)
                }

                ForEach(conversationItems) { item in
                    switch item {
                    case .userMessage(let text, let timestamp):
                        chatUserBubble(text: text, timestamp: timestamp)
                    case .agentResponse(let run):
                        chatAgentBubble(run: run)
                    case .scheduleResult(let text, let timestamp):
                        scheduleResultBubble(text: text, timestamp: timestamp)
                    case .systemInfo(let text, let timestamp):
                        systemInfoBubble(text: text, timestamp: timestamp)
                    case .recapResult(let text, let timestamp):
                        recapBubble(text: text, timestamp: timestamp)
                    }
                }

                if task.status == .running {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Agent is working…")
                            .font(Stanford.body(14))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                if task.status == .pendingUser {
                    if latestRun?.output.isEmpty ?? true {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(Stanford.ui(16))
                                .foregroundStyle(Stanford.poppy)
                            Text("Waiting for your approval")
                                .font(Stanford.body(13))
                                .foregroundStyle(Stanford.poppy)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Stanford.poppy.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Schedule creation: thinking indicator
                if isCreatingSchedule {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating schedule...")
                            .font(Stanford.body(13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Stanford.fog)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Recap generation: thinking indicator
                if isGeneratingRecap {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating recap...")
                            .font(Stanford.body(13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Stanford.fog)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Recap error/empty status
                if let msg = recapStatusMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Stanford.poppy)
                        Text(msg)
                            .font(Stanford.body(13))
                            .foregroundStyle(Stanford.black)
                        Spacer()
                        Button {
                            recapStatusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(Stanford.ui(10, weight: .bold))
                                .foregroundStyle(Stanford.coolGrey)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Stanford.fog)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Terminal status inline indicator (only for non-success outcomes)
                if task.isTerminal && task.status != .completed {
                    HStack(spacing: 8) {
                        Image(systemName: terminalStatusIcon)
                            .font(Stanford.ui(13))
                            .foregroundStyle(terminalStatusColor)
                        Text(terminalStatusLabel)
                            .font(Stanford.caption(13).weight(.medium))
                            .foregroundStyle(terminalStatusColor)
                        Spacer()
                        if let completedAt = task.completedAt {
                            Text(completedAt, style: .relative)
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.coolGrey)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(terminalStatusColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Schedule creation: result message
                if let statusMsg = scheduleStatusMessage {
                    HStack(spacing: 10) {
                        Image(systemName: isScheduleStatusError
                              ? "exclamationmark.triangle" : "clock.badge.checkmark")
                            .foregroundStyle(isScheduleStatusError
                                             ? Stanford.poppy : Stanford.paloAltoGreen)
                        Text(MarkdownTextView.markdownAttributed(statusMsg))
                            .font(Stanford.body(13))
                            .foregroundStyle(Stanford.black)
                        Spacer()
                        Button {
                            scheduleStatusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(Stanford.ui(10, weight: .bold))
                                .foregroundStyle(Stanford.coolGrey)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Stanford.fog)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Color.clear.frame(height: 1).id("chatBottom")
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear { proxy.scrollTo("chatBottom", anchor: .bottom) }
        .onChange(of: conversationItems.count) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        }
        .onChange(of: task.status) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        }
        }
    }

    private var isScheduleStatusError: Bool {
        guard let msg = scheduleStatusMessage else { return false }
        return msg.hasPrefix("Failed") || msg.hasPrefix("Could not") || msg.hasPrefix("Invalid")
    }

    private enum ConversationItem: Identifiable {
        case userMessage(text: String, timestamp: Date)
        case agentResponse(run: TaskRun)
        case scheduleResult(text: String, timestamp: Date)
        case systemInfo(text: String, timestamp: Date)
        case recapResult(text: String, timestamp: Date)

        var id: String {
            switch self {
            case .userMessage(_, let timestamp): return "user-\(timestamp.timeIntervalSince1970)"
            case .agentResponse(let run): return "agent-\(run.id)"
            case .scheduleResult(_, let timestamp): return "schedule-\(timestamp.timeIntervalSince1970)"
            case .systemInfo(_, let timestamp): return "system-\(timestamp.timeIntervalSince1970)"
            case .recapResult(_, let timestamp): return "recap-\(timestamp.timeIntervalSince1970)"
            }
        }
    }

    // MARK: - Chat Bubbles

    private func chatUserBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(Stanford.body(15))
                    .lineSpacing(5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Stanford.cardinalRed.opacity(0.08))
                    .foregroundStyle(Stanford.black)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 16
                    ))
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 16,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 16
                        )
                        .stroke(Stanford.cardinalRed.opacity(0.15), lineWidth: 1)
                    )
                    .textSelection(.enabled)

                Text(timestamp, style: .relative)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.trailing, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your message: \(text)")
    }

    private func scheduleResultBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.poppy)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(MarkdownTextView.markdownAttributed(text))
                    .font(Stanford.body(14))
                    .foregroundStyle(Stanford.black)
                    .textSelection(.enabled)

                Text(timestamp, style: .relative)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.fog)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Stanford.poppy.opacity(0.3), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Schedule result: \(text)")
    }

    private func systemInfoBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.plum)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Stanford.body(14))
                    .foregroundStyle(Stanford.black)

                Text(timestamp, style: .relative)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.plum.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Stanford.plum.opacity(0.3), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System notice: \(text)")
    }

    private func recapBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.paloAltoGreen)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                MarkdownTextView(text: text)

                Text(timestamp, style: .relative)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.paloAltoGreen.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Stanford.paloAltoGreen.opacity(0.3), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task recap")
    }

    private func chatAgentBubble(run: TaskRun) -> some View {
        let toolEvents = runToolEvents(for: run)
        let isExpanded = expandedRunActivity.contains(run.id)

        return VStack(alignment: .leading, spacing: 8) {
            // Collapsible tool activity
            if !toolEvents.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedRunActivity.remove(run.id)
                        } else {
                            expandedRunActivity.insert(run.id)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Stanford.ui(10, weight: .semibold))
                        Image(systemName: "wrench")
                            .font(Stanford.ui(11))
                        Text("\(toolEvents.count) tool \(toolEvents.count == 1 ? "call" : "calls")")
                            .font(Stanford.caption(12).weight(.medium))
                    }
                    .foregroundStyle(Stanford.coolGrey)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    toolActivityList(toolEvents, results: runToolResults(for: run))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Stanford.fog.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // VPN warning
            if run.output.contains("VPC_SERVICE_CONTROLS") || run.output.contains("SECURITY_POLICY_VIOLATED") || run.output.contains("Request is prohibited by organization's policy") {
                HStack(spacing: 10) {
                    Image(systemName: "network.slash")
                        .font(Stanford.ui(16))
                        .foregroundStyle(Stanford.poppy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN Connection Required")
                            .font(Stanford.ui(14, weight: .semibold))
                            .foregroundStyle(Stanford.black)
                        Text("Please verify your VPN is active. This error typically occurs when you're not connected to the organization's network.")
                            .font(Stanford.ui(13))
                            .foregroundStyle(Stanford.black)
                            .lineSpacing(3)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Stanford.poppy.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Stanford.poppy.opacity(0.3), lineWidth: 1))
            }

            // Response text — flows directly, no card
            MarkdownTextView(text: run.output)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            // Generated files
            if !generatedFiles.isEmpty && run.id == latestRun?.id {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(generatedFiles, id: \.self) { path in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: Formatters.fileIcon(for: path))
                                    .font(Stanford.ui(11))
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(Stanford.caption(12))
                                    .underline()
                            }
                            .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Action icons row
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.output, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Stanford.ui(12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                .help("Copy")

                if !run.fileChanges.isEmpty {
                    Button { selectedTab = .files } label: {
                        Image(systemName: "doc.text")
                            .font(Stanford.ui(12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                    .help("\(run.fileChanges.count) changed files")
                }

                Button {
                    let forked = AgentTask.fork(from: task, upToRun: run, in: modelContext)
                    try? modelContext.save()
                    onForkTask?(forked)
                } label: {
                    Image(systemName: "arrow.branch")
                        .font(Stanford.ui(12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                .help("Fork from here")

                Spacer()

                HStack(spacing: 8) {
                    if run.tokensUsed > 0 {
                        Text(Formatters.formatTokens(run.tokensUsed))
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                    }
                    if let completed = run.completedAt {
                        Text(formatDuration(Int(completed.timeIntervalSince(run.startedAt))))
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent response")
    }

    // MARK: - Run Tool Events

    /// Get tool events for a specific run, deduped and counted.
    private func runToolEvents(for run: TaskRun) -> [(name: String, count: Int)] {
        let events = task.events
            .filter { $0.run?.id == run.id && $0.type == "tool.use" }
            .sorted { $0.timestamp < $1.timestamp }

        var seen: [String: Int] = [:]
        var order: [String] = []
        for event in events {
            let name = event.payload.replacingOccurrences(of: "Using tool: ", with: "")
            if seen[name] != nil {
                seen[name]! += 1
            } else {
                seen[name] = 1
                order.append(name)
            }
        }
        return order.map { (name: $0, count: seen[$0]!) }
    }

    /// Get tool result events for a specific run, ordered chronologically.
    private func runToolResults(for run: TaskRun) -> [TaskEvent] {
        task.events
            .filter { $0.run?.id == run.id && $0.type == "tool.result" && !$0.payload.isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
    }

    @ViewBuilder
    private func toolActivityList(_ tools: [(name: String, count: Int)], results: [TaskEvent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tools, id: \.name) { item in
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(item.name))
                        .font(Stanford.ui(11))
                        .foregroundStyle(Stanford.poppy)
                        .frame(width: 14)
                    Text(item.name)
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(Stanford.black)
                    if item.count > 1 {
                        Text("×\(item.count)")
                            .font(Stanford.caption(11))
                            .foregroundStyle(Stanford.poppy.opacity(0.7))
                    }
                }
            }
            // Show tool results inline
            ForEach(results) { result in
                toolResultView(result.payload)
            }
        }
    }

    @ViewBuilder
    private func toolResultView(_ content: String) -> some View {
        let displayContent = content.count > 5000 ? String(content.prefix(5000)) + "\n… (truncated)" : content
        ScrollView(.horizontal, showsIndicators: false) {
            Text(displayContent)
                .font(Stanford.ui(12, design: .monospaced))
                .foregroundStyle(Stanford.black)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
        .background(Stanford.fog.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }

    private func runStatusIcon(_ run: TaskRun) -> String {
        switch run.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .budgetExceeded: return "exclamationmark.triangle.fill"
        case .running: return "circle.dotted"
        case .timeout: return "clock.badge.exclamationmark"
        }
    }

    private func runStatusColor(_ run: TaskRun) -> Color {
        switch run.status {
        case .completed: return Stanford.paloAltoGreen
        case .failed, .budgetExceeded, .timeout: return Stanford.cardinalRed
        case .cancelled: return Stanford.coolGrey
        case .running: return Stanford.lagunita
        }
    }

    private func runStatusLabel(_ run: TaskRun) -> String {
        switch run.status {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .budgetExceeded: return "Budget exceeded"
        case .running: return "Running"
        case .timeout: return "Timed out"
        }
    }

    // MARK: - Chat Thread

    private var sortedEvents: [TaskEvent] {
        task.events.sorted { $0.timestamp < $1.timestamp }
    }

    private var latestRun: TaskRun? {
        task.runs.sorted { $0.startedAt > $1.startedAt }.first
    }

    private var isFinished: Bool {
        [.completed, .pendingUser, .failed, .budgetExceeded, .cancelled].contains(task.status)
    }

    // (Activity tab removed — tool events are shown inline in agent response bubbles)

    // MARK: - Result Helpers

    @ViewBuilder
    private var resultSummaryView: some View {
        if let run = latestRun {
            let fileCount = run.fileChanges.count
            let writeCount = run.fileChanges.filter { $0.changeType == "Write" }.count
            let editCount = run.fileChanges.filter { $0.changeType == "Edit" }.count

            VStack(alignment: .leading, spacing: 6) {
                if task.status == .pendingUser {
                    Label("Review the output, then **Approve** or **Retry**.", systemImage: "info.circle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.poppy)
                } else if task.status == .completed {
                    Label("Task completed successfully.", systemImage: "checkmark.seal")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.paloAltoGreen)
                } else if task.status == .failed {
                    Label(failureReason, systemImage: "exclamationmark.triangle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.cardinalRed)
                    if task.sessionId != nil {
                        Text("**Resume** to continue or **Retry** to start over.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                } else if task.status == .budgetExceeded {
                    Label("Budget exhausted (\(Formatters.formatTokens(task.tokensUsed))/\(Formatters.formatTokens(task.tokenBudget))).", systemImage: "exclamationmark.triangle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.cardinalRed)
                    if task.sessionId != nil {
                        Text("**Resume** with a higher budget or **Retry** fresh.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                }

                if fileCount > 0 {
                    HStack(spacing: 10) {
                        if writeCount > 0 {
                            Label("\(writeCount) created", systemImage: "doc.badge.plus")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.paloAltoGreen)
                        }
                        if editCount > 0 {
                            Label("\(editCount) edited", systemImage: "pencil")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.lagunita)
                        }
                    }
                }
            }
        }
    }

    private var resultIcon: String {
        switch task.status {
        case .completed: return "checkmark.circle.fill"
        case .pendingUser: return "person.crop.circle.badge.questionmark"
        case .failed, .budgetExceeded: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "circle.fill"
        }
    }

    private var resultColor: Color {
        switch task.status {
        case .completed: return Stanford.paloAltoGreen
        case .pendingUser: return Stanford.poppy
        case .failed, .budgetExceeded: return Stanford.cardinalRed
        case .cancelled: return Stanford.coolGrey
        default: return Stanford.lagunita
        }
    }

    private var resultTitle: String {
        switch task.status {
        case .completed: return "Task Completed"
        case .pendingUser: return "Awaiting Your Review"
        case .failed: return "Task Failed"
        case .budgetExceeded: return "Budget Exceeded"
        case .cancelled: return "Task Cancelled"
        default: return "Result"
        }
    }

    private var failureReason: String {
        let errorEvents = task.events.filter { $0.type == "error" }
        if let lastError = errorEvents.last {
            let payload = lastError.payload
            if payload.contains("idle timeout") || payload.contains("timed out") {
                return "Agent went idle — no output for the timeout period."
            }
            if payload.contains("CLI not found") {
                return "Claude CLI not found. Check Settings."
            }
            if payload.contains("not found") || payload.contains("Workspace") {
                return "Workspace directory not found."
            }
            if payload.contains("isolation") || payload.contains("Isolation") {
                return "Workspace isolation setup failed."
            }
            if payload.contains("exit") || payload.contains("exited") {
                if let run = latestRun {
                    if run.exitCode == 143 { return "Process killed (SIGTERM) — likely timeout." }
                    if run.exitCode == 137 { return "Process killed (SIGKILL) — may be out of memory." }
                    if run.exitCode != 0 { return "Agent exited with code \(run.exitCode ?? -1)." }
                }
            }
            return String(payload.prefix(200))
        }
        if let run = latestRun, run.exitCode == 143 {
            return "Process killed (SIGTERM) — likely timeout."
        }
        return "The agent encountered an error. Check the activity log."
    }

    // MARK: - Terminal Status Helpers

    private var terminalStatusIcon: String {
        switch task.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .budgetExceeded: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle.fill"
        default: return "circle.fill"
        }
    }

    private var terminalStatusColor: Color {
        switch task.status {
        case .completed: return Stanford.paloAltoGreen
        case .failed, .budgetExceeded: return Stanford.cardinalRed
        case .cancelled: return Stanford.coolGrey
        default: return Stanford.coolGrey
        }
    }

    private var terminalStatusLabel: String {
        switch task.status {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .budgetExceeded: return "Budget Exceeded"
        case .cancelled: return "Cancelled"
        default: return ""
        }
    }

    // MARK: - Composer

    private var hasInput: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    private var showSlashMenu: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ") && trimmed.count < 14
    }

    private var slashMenuMatchesRemember: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/remember".hasPrefix(trimmed)
    }

    private var slashMenuMatchesSchedule: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/schedule".hasPrefix(trimmed)
    }

    private var slashMenuMatchesRecap: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/recap".hasPrefix(trimmed)
    }

    private var visibleSlashOptions: [(id: String, command: String)] {
        var opts: [(id: String, command: String)] = []
        if slashMenuMatchesRemember { opts.append(("remember", "/remember ")) }
        if slashMenuMatchesSchedule { opts.append(("schedule", "/schedule ")) }
        if slashMenuMatchesRecap { opts.append(("recap", "/recap")) }
        return opts
    }

    /// Icon / color / title / subtitle metadata for a slash option id.
    private static func slashOptionMeta(_ id: String) -> (icon: String, color: Color, title: String, subtitle: String) {
        switch id {
        case "remember":
            return ("brain", Stanford.plum, "Add Memory", "Save a fact to this workspace's memory")
        case "schedule":
            return ("clock.badge.checkmark", Stanford.poppy, "Create Schedule", "Automate this task on a recurring schedule")
        case "recap":
            return ("doc.text", Stanford.paloAltoGreen, "Recap Task", "Summarize progress so you can pause and resume later")
        default:
            return ("questionmark", Stanford.coolGrey, id.capitalized, "")
        }
    }

    private func selectSlashOption() {
        let opts = visibleSlashOptions
        guard !opts.isEmpty else { return }
        let idx = min(slashSelectedIndex, opts.count - 1)
        selectSlashOption(opts[idx])
    }

    /// Commands that take no argument execute immediately on selection.
    /// Commands that take args just fill the composer so the user can type.
    private func selectSlashOption(_ opt: (id: String, command: String)) {
        messageText = opt.command
        if Self.isNoArgSlashCommand(opt.id) {
            sendMessage()
        }
    }

    private static func isNoArgSlashCommand(_ id: String) -> Bool {
        id == "recap"
    }

    private var composerPlaceholder: String {
        switch task.status {
        case .queued: return "Type to refine this task (moves back to draft)..."
        case .completed: return "Ask a follow-up question..."
        case .pendingUser: return "Send a message to continue..."
        default: return "Send a message..."
        }
    }

    private var composerView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachedFiles, id: \.self) { file in
                                fileChip(file)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    }
                }

                TextField(composerPlaceholder, text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Stanford.ui(16))
                    .lineLimit(3...12)
                    .padding(.horizontal, 18)
                    .padding(.top, attachedFiles.isEmpty ? 16 : 8)
                    .padding(.bottom, 12)
                    .onSubmit {
                        if showSlashMenu && !visibleSlashOptions.isEmpty {
                            selectSlashOption()
                        } else {
                            sendMessage()
                        }
                    }
                    .onKeyPress(.tab) {
                        if showSlashMenu && !visibleSlashOptions.isEmpty { selectSlashOption(); return .handled }
                        return .ignored
                    }
                    .onKeyPress(.upArrow) {
                        if showSlashMenu {
                            slashSelectedIndex = max(0, slashSelectedIndex - 1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        if showSlashMenu {
                            slashSelectedIndex = min(visibleSlashOptions.count - 1, slashSelectedIndex + 1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onChange(of: messageText) { slashSelectedIndex = 0 }
                    .disabled(task.status == .running)

                Color.clear
                    .frame(height: 2)

                ComposerToolbar(
                    model: task.model,
                    budget: task.tokenBudget,
                    skills: task.skills,
                    availableSkills: availableSkills,
                    workspace: task.workspace,
                    isRunning: task.status == .running,
                    hasInput: hasInput,
                    onAttachFile: { attachFile() },
                    onPasteClipboard: { smartPaste() },
                    onSend: { sendMessage() },
                    onStop: { onCancelTask?(task) },
                    onModelChange: { task.model = $0 },
                    onBudgetChange: { task.tokenBudget = $0 },
                    onRemoveSkill: { skill in
                        task.skills.removeAll { $0.id == skill.id }
                        task.captureSkillSnapshots()
                        task.updatedAt = Date()
                    },
                    onToggleSkill: { skill, enabled in
                        if enabled {
                            if !task.skills.contains(where: { $0.id == skill.id }) {
                                task.skills.append(skill)
                            }
                        } else {
                            task.skills.removeAll { $0.id == skill.id }
                        }
                        task.captureSkillSnapshots()
                        task.updatedAt = Date()
                    },
                    onManageSkills: onManageSkills,
                    skipPermissions: .constant(false),
                    useAgentTeam: .constant(false),
                    teamSize: .constant(3),
                    isPlanMode: .constant(false)
                )
            }
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isDragOver ? Stanford.cardinalRed : Stanford.sandstone.opacity(0.3), lineWidth: isDragOver ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .overlay(alignment: .topLeading) {
                if showSlashMenu && !visibleSlashOptions.isEmpty {
                    let opts = visibleSlashOptions
                    VStack(spacing: 0) {
                        ForEach(Array(opts.enumerated()), id: \.element.id) { index, opt in
                            let isSelected = index == min(slashSelectedIndex, opts.count - 1)
                            let meta = Self.slashOptionMeta(opt.id)
                            Button {
                                selectSlashOption(opt)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: meta.icon)
                                        .font(Stanford.body(16))
                                        .foregroundStyle(meta.color)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(opt.command.trimmingCharacters(in: .whitespaces))
                                                .font(Stanford.body(14)).fontWeight(.semibold)
                                            Text(meta.title)
                                                .font(Stanford.caption(13)).foregroundStyle(Stanford.coolGrey)
                                        }
                                        Text(meta.subtitle)
                                            .font(Stanford.caption(12))
                                            .foregroundStyle(Stanford.coolGrey)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(isSelected ? Stanford.coolGrey.opacity(0.1) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: 420)
                    .background(.ultraThickMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                    .offset(y: -CGFloat(visibleSlashOptions.count) * 52 - 16)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDragOver) { providers in
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            var fileURL: URL?
                            if let data = item as? Data {
                                fileURL = URL(dataRepresentation: data, relativeTo: nil)
                            } else if let url = item as? URL {
                                fileURL = url
                            }
                            guard let url = fileURL else { return }
                            DispatchQueue.main.async {
                                if !attachedFiles.contains(url.path) {
                                    attachedFiles.append(url.path)
                                }
                            }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                            guard let data else { return }
                            let tempPath = NSTemporaryDirectory() + "astra_drop_\(UUID().uuidString.prefix(8)).png"
                            try? data.write(to: URL(fileURLWithPath: tempPath))
                            DispatchQueue.main.async {
                                attachedFiles.append(tempPath)
                            }
                        }
                    }
                }
                return true
            }
        }
    }

    /// Smart paste: inspect clipboard and route to the right action.
    /// Returns true if it handled the paste (non-text content), false to
    /// let the TextField handle it natively (short text).
    @discardableResult
    private func smartPaste() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        // 1. File URLs — attach directly
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls where !attachedFiles.contains(url.path) {
                attachedFiles.append(url.path)
            }
            return true
        }

        // 2. Image data (screenshot, copied image) — save as temp PNG
        if types.contains(.png) || types.contains(.tiff) {
            if let image = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let first = image.first {
                if let tiff = first.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).png"
                    try? png.write(to: URL(fileURLWithPath: tempPath))
                    attachedFiles.append(tempPath)
                    return true
                }
            }
        }

        // 3. Text — short text pastes inline, long text attaches as file
        if let text = pb.string(forType: .string), !text.isEmpty {
            let lineCount = text.components(separatedBy: .newlines).count
            if lineCount > 10 || text.count > 500 {
                let ext = text.hasPrefix("{") || text.hasPrefix("[") ? "json" : "txt"
                let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).\(ext)"
                try? text.write(toFile: tempPath, atomically: true, encoding: .utf8)
                attachedFiles.append(tempPath)
                return true
            }
            return false
        }

        return false
    }

    /// Autocomplete /schedule in the composer with a trailing space for inline instructions.
    private func selectSlashSchedule() {
        messageText = "/schedule "
    }

    // MARK: - Agentic Schedule Creation

    private static let jsonBlockRegex = try? NSRegularExpression(
        pattern: "```json\\s*\\n([\\s\\S]*?)\\n\\s*```",
        options: []
    )

    /// Use Claude to analyze the conversation context + user instruction and create a schedule.
    /// Ask Claude to summarize the task conversation so the user can resume later.
    /// Response is plain markdown (no JSON), inserted as a recap.result event.
    private func generateRecapAgentically() {
        let conversationSnapshot = scheduleConversationContext
        guard !conversationSnapshot.isEmpty else {
            recapStatusMessage = "Nothing to recap yet — this task has no conversation."
            return
        }

        isGeneratingRecap = true
        recapStatusMessage = nil

        let workspacePath = task.workspace?.primaryPath ?? ""

        let systemPrompt = """
        The user typed /recap. They are the sole reader and will use this to resume their own work on this task after a context switch.

        Read the conversation above and produce a recap in this exact format. OMIT any section that would be empty — don't write "(none)" or placeholders.

        ## Goal
        One sentence describing what "done" looks like for this task.

        ## Progress
        - Bullets: what was done, plus the non-obvious *why* behind any decision (decisions rot fastest from memory).
        - Max 5 bullets.

        ## Next steps
        - Ordered bullets of concrete actions. The first one must be immediately executable without further thinking.
        - Max 5 bullets.

        ## Watch out
        - Gotchas, blockers, dead-ends already ruled out, things waiting on someone else.
        - Skip this section entirely if there's nothing meaningful to flag.

        Rules:
        - Target ≤150 words total, hard cap 250.
        - Markdown only. No preamble, no sign-off, no meta commentary like "Here is your recap".
        - If the conversation has fewer than ~3 substantive exchanges, reply with a single sentence saying there isn't enough yet to recap.

        Current task title: \(task.title)
        Current task goal: \(task.goal)
        """

        let messages: [(role: String, content: String)] = [
            (role: "user", content: """
            Here is the conversation so far on this task:

            \(String(conversationSnapshot.prefix(12000)))
            """)
        ]

        Task {
            let result = await SpecEngine.chat(
                messages: messages,
                workspacePath: workspacePath,
                skillContext: systemPrompt,
                model: task.model
            )

            await MainActor.run {
                switch result {
                case .success(let response):
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        isGeneratingRecap = false
                        recapStatusMessage = "Recap came back empty. Try again."
                        return
                    }
                    let event = TaskEvent(task: task, type: "recap.result", payload: trimmed)
                    modelContext.insert(event)
                    // Force a save so the inverse relationship (task.events) fires
                    // observation immediately — otherwise the bubble can lag behind
                    // the spinner by several seconds.
                    try? modelContext.save()
                    task.updatedAt = Date()
                    isGeneratingRecap = false
                case .failure(let error):
                    isGeneratingRecap = false
                    recapStatusMessage = "Failed to generate recap: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createScheduleAgentically(instruction: String) {
        guard let ws = task.workspace else {
            scheduleStatusMessage = "No workspace found for this task."
            return
        }

        isCreatingSchedule = true
        scheduleStatusMessage = nil

        let conversationSnapshot = scheduleConversationContext
        let existingSchedules = ws.schedules.map { "\($0.name) (\($0.frequencySummary))" }.joined(separator: ", ")
        let skillList = availableSkills.map { $0.name }.joined(separator: ", ")
        let workspacePath = ws.primaryPath

        let systemPrompt = """
        You are a scheduling assistant. The user is working on an existing task and wants to create a recurring schedule from it.

        Analyze the user's instruction and the conversation context to create a schedule. You must output a single JSON block with the schedule configuration.

        ## Rules
        - Infer the schedule type (once, interval, daily, weekly) from the instruction
        - Write a detailed, self-contained goal that captures the full intent from both the instruction AND the conversation context
        - The goal should be specific enough that an agent running this schedule later (with no other context) can execute it correctly
        - Pick a short, descriptive name for the schedule
        - If the instruction mentions a time, use it. Otherwise pick a sensible default (9:00 for daily, Monday 9:00 for weekly)
        - For interval: common values are 900 (15m), 1800 (30m), 3600 (1h), 14400 (4h), 43200 (12h)
        - For daily/weekly: hour is 0-23, minute is 0/15/30/45
        - For weekly: dayOfWeek 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday

        Existing schedules: \(existingSchedules.isEmpty ? "none" : existingSchedules)
        Available skills to attach: \(skillList.isEmpty ? "none" : skillList)

        Current task title: \(task.title)
        Current task goal: \(task.goal)

        Output ONLY a JSON block — no other text:
        ```json
        {"name": "...", "goal": "detailed goal text", "scheduleType": "daily|weekly|interval|once", "intervalSeconds": 3600, "dailyHour": 9, "dailyMinute": 0, "weeklyDayOfWeek": 2, "skills": ["skill name", ...], "model": "\(task.model)"}
        ```
        Only include fields relevant to the chosen scheduleType. skills is optional — only include if the instruction or context references specific skills.
        """

        let messages: [(role: String, content: String)] = [
            (role: "user", content: """
            Here is the conversation context from the current task:

            \(conversationSnapshot.isEmpty ? "(no conversation yet)" : String(conversationSnapshot.prefix(8000)))

            ---

            Create a schedule: \(instruction)
            """)
        ]

        Task {
            let result = await SpecEngine.chat(
                messages: messages,
                workspacePath: workspacePath,
                skillContext: systemPrompt,
                model: task.model
            )

            await MainActor.run {
                isCreatingSchedule = false

                switch result {
                case .success(let response):
                    parseAndCreateSchedule(from: response, workspace: ws)
                case .failure(let error):
                    scheduleStatusMessage = "Failed to create schedule: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Parse Claude's JSON response and create the TaskSchedule.
    private func parseAndCreateSchedule(from response: String, workspace: Workspace) {
        guard let regex = Self.jsonBlockRegex,
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let jsonRange = Range(match.range(at: 1), in: response) else {
            // Try parsing the whole response as JSON (Claude sometimes skips the fences)
            if let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                createScheduleFromJSON(json, workspace: workspace)
                return
            }
            scheduleStatusMessage = "Could not parse schedule configuration. Try again with clearer instructions."
            return
        }

        let jsonStr = String(response[jsonRange])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            scheduleStatusMessage = "Invalid schedule configuration. Try again."
            return
        }

        createScheduleFromJSON(json, workspace: workspace)
    }

    /// Create a TaskSchedule from parsed JSON fields.
    private func createScheduleFromJSON(_ json: [String: Any], workspace: Workspace) {
        let name = json["name"] as? String ?? task.title
        let goal = json["goal"] as? String ?? task.goal
        let scheduleTypeRaw = json["scheduleType"] as? String ?? "daily"
        let scheduleType = ScheduleType(rawValue: scheduleTypeRaw) ?? .daily

        let schedule = TaskSchedule(name: name, goal: goal, workspace: workspace, scheduleType: scheduleType)

        if let interval = json["intervalSeconds"] as? Int { schedule.intervalSeconds = interval }
        if let hour = json["dailyHour"] as? Int { schedule.dailyHour = hour }
        if let minute = json["dailyMinute"] as? Int { schedule.dailyMinute = minute }
        if let dow = json["weeklyDayOfWeek"] as? Int { schedule.weeklyDayOfWeek = dow }
        if let m = json["model"] as? String { schedule.model = m } else { schedule.model = task.model }

        schedule.tokenBudget = task.tokenBudget
        schedule.conversationContext = scheduleConversationContext
        schedule.sourceTaskID = task.id

        // Compute initial nextFireDate
        let now = Date()
        switch scheduleType {
        case .once:
            schedule.nextFireDate = now.addingTimeInterval(60)
        case .interval:
            schedule.nextFireDate = now.addingTimeInterval(TimeInterval(schedule.intervalSeconds))
        case .daily:
            schedule.nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86400)
        case .weekly:
            schedule.nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute, weekday: schedule.weeklyDayOfWeek),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(604800)
        }

        // Attach skills by name
        if let skillNames = json["skills"] as? [String] {
            let matchedIDs = workspace.skills.filter { skillNames.contains($0.name) }.map { $0.id.uuidString }
            schedule.skillIDs = matchedIDs
        }

        modelContext.insert(schedule)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        scheduleStatusMessage = "Schedule **\(name)** created — \(schedule.frequencySummary)"

        AppLogger.audit(.taskStats, category: "UI", fields: [
            "event": "schedule_created",
            "source": "agentic_slash_command",
            "workspace_id": workspace.id.uuidString,
            "schedule_type": scheduleTypeRaw
        ])
    }

    // MARK: - Helpers

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty else { return }

        // Intercept /remember command — direct action, no Claude call needed
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("/remember ") {
            let memoryText = String(trimmed.dropFirst("/remember ".count)).trimmingCharacters(in: .whitespaces)
            if !memoryText.isEmpty {
                task.workspace?.memories.append(memoryText)
                let confirmEvent = TaskEvent(task: task, type: "system.info", payload: "💾 Memory saved: \"\(memoryText)\"")
                modelContext.insert(confirmEvent)
            }
            messageText = ""
            return
        }

        // Intercept /recap command — agentic summary, no Claude session needed
        if lower == "/recap" || lower.hasPrefix("/recap ") {
            messageText = ""
            generateRecapAgentically()
            return
        }

        // Intercept /schedule command — use agentic handler
        if lower == "/schedule" || lower.hasPrefix("/schedule ") {
            let instructions = lower == "/schedule" ? "" : String(trimmed.dropFirst("/schedule ".count)).trimmingCharacters(in: .whitespaces)
            messageText = ""
            if instructions.isEmpty {
                // No instructions — open the manual schedule editor
                showScheduleEditor = true
            } else {
                // Agentic: Claude analyzes the instruction + conversation context
                createScheduleAgentically(instruction: instructions)
            }
            return
        }

        var msg = messageText
        if !attachedFiles.isEmpty {
            let fileList = attachedFiles.map { "- \($0)" }.joined(separator: "\n")
            msg += "\n\nAttached files:\n\(fileList)"
            attachedFiles = []
        }
        messageText = ""

        if task.status == .queued {
            task.status = .draft
            task.updatedAt = Date()
            let systemEvent = TaskEvent(task: task, type: "task.started", payload: "Moved back to draft for editing.")
            modelContext.insert(systemEvent)
            let userEvent = TaskEvent(task: task, type: "user.message", payload: msg)
            modelContext.insert(userEvent)
            AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
                "status": "draft",
                "source": "chat_message"
            ])
            onMoveToDraft?(task)
        } else if [.pendingUser, .completed, .failed, .budgetExceeded, .cancelled].contains(task.status), let taskQueue {
            // Note: don't insert user.message here — continueSession() does it with the TaskRun link
            task.status = .running
            task.updatedAt = Date()
            task.completedAt = nil
            Task {
                await taskQueue.continueSession(task: task, message: msg, modelContext: modelContext) { _ in }
            }
        } else {
            let event = TaskEvent(task: task, type: "user.message", payload: msg)
            modelContext.insert(event)
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]

    private func fileChip(_ file: String) -> some View {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        let isImage = Self.imageExtensions.contains(ext)

        return HStack(spacing: 6) {
            if isImage, let nsImage = NSImage(contentsOfFile: file) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: Formatters.fileIcon(for: file))
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.lagunita)
            }
            Text(URL(fileURLWithPath: file).lastPathComponent)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0 == file }
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Stanford.fog)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Stanford.sandstone.opacity(0.4), lineWidth: 0.5))
    }

    /// Files in the task folder (excluding session_history.md and outputs/)
    private var generatedFiles: [String] {
        let folder = task.taskFolder
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { return [] }
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return [] }
        var files: [String] = []
        while let rel = enumerator.nextObject() as? String {
            if rel.hasPrefix("outputs/") || rel == "session_history.md" { continue }
            let full = (folder as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if !isDir.boolValue { files.append(full) }
        }
        return files
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files or images to attach"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !attachedFiles.contains(url.path) {
                    attachedFiles.append(url.path)
                }
            }
        }
    }


    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    /// Context window limit per model (all current models use 200K)
    private var contextWindowLimit: Int {
        200_000
    }

    /// Compact context window gauge showing input tokens vs model limit
    private func contextGauge(inputTokens: Int) -> some View {
        let limit = contextWindowLimit
        let pct = min(Double(inputTokens) / Double(limit), 1.0)
        let color: Color = pct > 0.85 ? Stanford.cardinalRed : pct > 0.6 ? Stanford.poppy : Stanford.paloAltoGreen

        return HStack(spacing: 4) {
            // Mini progress arc
            ZStack {
                Circle()
                    .stroke(Stanford.sandstone.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: pct)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)

            Text("\(Formatters.formatTokens(inputTokens))/\(Formatters.formatTokens(limit))")
                .font(Stanford.caption(11).monospacedDigit())
                .foregroundStyle(color)
        }
        .help("Context window: \(Formatters.formatTokens(inputTokens)) of \(Formatters.formatTokens(limit)) tokens used (\(Int(pct * 100))%)")
    }
}

// MARK: - Markdown Text View

/// Renders text as formatted markdown with support for headers, bold, italic,
/// code blocks, lists, tables, dividers, blockquotes, and system notices.
struct MarkdownTextView: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .codeBlock(let lang):
                    codeBlockView(lang: lang, code: block.content)

                case .table:
                    tableView(block.content)

                case .divider:
                    Divider()
                        .padding(.vertical, 6)

                case .heading(let level):
                    Text(Self.markdownAttributed(block.content))
                        .font(level == 1 ? Stanford.heading(22, weight: .bold) : level == 2 ? Stanford.heading(18) : Stanford.heading(16))
                        .foregroundStyle(Stanford.black)
                        .padding(.top, level == 1 ? 14 : 10)
                        .padding(.bottom, 2)

                case .listItem(let depth):
                    HStack(alignment: .top, spacing: 8) {
                        Text(depth == 0 ? "\u{2022}" : "\u{25E6}")
                            .font(Stanford.ui(depth == 0 ? 15 : 13))
                            .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                            .frame(width: 14, alignment: .center)
                            .padding(.leading, CGFloat(depth) * 16)
                        Text(Self.markdownAttributed(block.content))
                            .font(Stanford.ui(15))
                            .foregroundStyle(Stanford.black)
                            .textSelection(.enabled)
                            .lineSpacing(5)
                    }

                case .blockquote:
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Stanford.sandstone.opacity(0.5))
                            .frame(width: 3)
                        Text(Self.markdownAttributed(block.content))
                            .font(Stanford.ui(15))
                            .italic()
                            .foregroundStyle(.primary.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .lineSpacing(5)
                    }
                    .background(Stanford.fog.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                case .notice:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(Stanford.ui(14))
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.top, 1)
                        Text(block.content)
                            .font(Stanford.ui(14))
                            .foregroundStyle(Stanford.black)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Stanford.lagunita.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                case .label:
                    Text(Self.markdownAttributed(block.content))
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(Stanford.black)
                        .padding(.top, 8)

                case .blank:
                    Spacer().frame(height: 12)

                case .text:
                    Text(Self.markdownAttributed(block.content))
                        .font(Stanford.ui(15))
                        .foregroundStyle(Stanford.black)
                        .textSelection(.enabled)
                        .lineSpacing(6)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
        .onAppear { blocks = Self.parse(text) }
        .onChange(of: text) { _, newText in blocks = Self.parse(newText) }
    }

    // MARK: - Code Block

    private func codeBlockView(lang: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(Stanford.ui(12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Stanford.coolGrey)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(Stanford.ui(11))
                            Text("Copy")
                                .font(Stanford.ui(11))
                        }
                        .foregroundStyle(Stanford.coolGrey)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Stanford.ui(14, design: .monospaced))
                    .foregroundStyle(Stanford.black)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Table Rendering

    private func tableView(_ raw: String) -> some View {
        let rows = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        let parsed = rows.compactMap { row -> [String]? in
            let cells = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) }) { return nil }
            return cells
        }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { rowIdx, cells in
                HStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(Stanford.ui(15, weight: rowIdx == 0 ? .semibold : .regular))
                            .foregroundStyle(Stanford.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }
                .background(rowIdx == 0 ? Stanford.fog.opacity(0.5) : (rowIdx % 2 == 0 ? Stanford.fog.opacity(0.2) : Color.clear))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: - Parsing

    enum BlockKind: Equatable {
        case text
        case codeBlock(language: String)
        case table
        case divider
        case heading(level: Int)
        case listItem(depth: Int)
        case blockquote
        case notice
        case label
        case blank
    }

    struct MarkdownBlock: Identifiable {
        let id = UUID()
        let kind: BlockKind
        let content: String
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(MarkdownBlock(kind: .text, content: joined))
            }
            textBuffer = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block (```)
            if trimmed.hasPrefix("```") {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(kind: .codeBlock(language: lang), content: codeLines.joined(separator: "\n")))
                continue
            }

            // Horizontal rule / divider (---, ***, ___)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
                i += 1
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushText()
                // Only add blank if the previous block wasn't already a blank/divider
                if let last = blocks.last, last.kind != .blank && last.kind != .divider {
                    blocks.append(MarkdownBlock(kind: .blank, content: ""))
                }
                i += 1
                continue
            }

            // Headings (# ## ###)
            if trimmed.hasPrefix("# ") {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: 1), content: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: 2), content: String(trimmed.dropFirst(3))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("### ") {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: 3), content: String(trimmed.dropFirst(4))))
                i += 1
                continue
            }

            // List items (- item, * item, + item, or numbered 1. item)
            if let listMatch = Self.listItemMatch(trimmed) {
                flushText()
                let depth = (line.count - line.drop(while: { $0 == " " }).count) / 2
                blocks.append(MarkdownBlock(kind: .listItem(depth: min(depth, 3)), content: listMatch))
                i += 1
                continue
            }

            // Blockquotes (> text)
            if trimmed.hasPrefix("> ") {
                flushText()
                var quoteLines: [String] = [String(trimmed.dropFirst(2))]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("> ") {
                        quoteLines.append(String(nextTrimmed.dropFirst(2)))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .blockquote, content: quoteLines.joined(separator: "\n")))
                continue
            }

            // System notices: [Reminder: ...], [Note: ...], [Warning: ...]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") &&
               (trimmed.contains("Reminder:") || trimmed.contains("Note:") || trimmed.contains("Warning:")) {
                flushText()
                let inner = String(trimmed.dropFirst().dropLast())
                blocks.append(MarkdownBlock(kind: .notice, content: inner))
                i += 1
                continue
            }

            // Label lines: "Something:" at end of a short line (< 60 chars, ends with colon)
            if trimmed.hasSuffix(":") && trimmed.count < 60 && !trimmed.contains("//") {
                flushText()
                blocks.append(MarkdownBlock(kind: .label, content: trimmed))
                i += 1
                continue
            }

            // Table detection (line with |)
            if trimmed.hasPrefix("|") && trimmed.contains("|") {
                var tableLines: [String] = [line]
                var j = i + 1
                var hasSeparator = false
                while j < lines.count && lines[j].contains("|") {
                    let nextTrimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("|") {
                        tableLines.append(lines[j])
                        let cells = nextTrimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                        if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) }) {
                            hasSeparator = true
                        }
                    } else {
                        break
                    }
                    j += 1
                }
                if hasSeparator && tableLines.count >= 3 {
                    flushText()
                    blocks.append(MarkdownBlock(kind: .table, content: tableLines.joined(separator: "\n")))
                    i = j
                    continue
                }
            }

            textBuffer.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    /// Match list item prefixes: "- ", "* ", "+ ", "1. ", "2. " etc.
    private static func listItemMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("+ ") { return String(trimmed.dropFirst(2)) }
        // Numbered: "1. ", "2. ", etc.
        if let dotIdx = trimmed.firstIndex(of: "."),
           dotIdx != trimmed.startIndex,
           trimmed[trimmed.startIndex..<dotIdx].allSatisfy(\.isNumber),
           trimmed.index(after: dotIdx) < trimmed.endIndex,
           trimmed[trimmed.index(after: dotIdx)] == " " {
            return String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...])
        }
        return nil
    }

    static func markdownAttributed(_ text: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }

        // Auto-detect bare URLs and make them clickable
        let plain = String(attributed.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length))
            for match in matches {
                guard let url = match.url,
                      let swiftRange = Range(match.range, in: plain) else { continue }
                let start = attributed.characters.index(
                    attributed.startIndex,
                    offsetBy: plain.distance(from: plain.startIndex, to: swiftRange.lowerBound)
                )
                let end = attributed.characters.index(
                    start,
                    offsetBy: plain.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
                )
                if attributed[start..<end].runs.allSatisfy({ $0.link == nil }) {
                    attributed[start..<end].link = url
                }
            }
        }

        return attributed
    }
}

// MARK: - Clickable Path Text

struct ClickablePathText: View {
    let text: String
    let workspacePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let lineSegments = Self.parseSegments(from: line, workspacePath: workspacePath)
                if lineSegments.contains(where: { $0.isPath }) {
                    HStack(spacing: 0) {
                        ForEach(lineSegments) { seg in
                            if seg.isPath {
                                Button {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: seg.resolvedPath!))
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: seg.isDirectory ? "folder.fill" : "doc.fill")
                                            .font(Stanford.ui(11))
                                        Text(seg.text)
                                            .underline()
                                    }
                                    .font(Stanford.ui(14, design: .monospaced))
                                    .foregroundStyle(Stanford.lagunita)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(seg.resolvedPath!)")
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            } else {
                                Text(markdownInline(seg.text))
                                    .font(Stanford.body(15))
                                    .foregroundStyle(Stanford.black)
                            }
                        }
                    }
                } else {
                    Text(markdownInline(line))
                        .font(Stanford.body(15))
                        .foregroundStyle(Stanford.black)
                        .textSelection(.enabled)
                }
            }
        }
        .lineSpacing(4)
    }

    private func markdownInline(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }

    // MARK: - Path Detection

    struct TextSegment: Identifiable {
        let id = UUID()
        let text: String
        let resolvedPath: String?
        let isDirectory: Bool

        var isPath: Bool { resolvedPath != nil }
    }

    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?:(?:/[\w.@\-]+)+(?:\.\w+)?|(?:\.{0,2}/)?(?:[\w.@\-]+/)+[\w.@\-]+(?:\.\w+)?)"#
    )

    static func parseSegments(from text: String, workspacePath: String) -> [TextSegment] {
        guard let regex = pathRegex else {
            return [TextSegment(text: text, resolvedPath: nil, isDirectory: false)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        if matches.isEmpty {
            return [TextSegment(text: text, resolvedPath: nil, isDirectory: false)]
        }

        var segments: [TextSegment] = []
        var lastEnd = 0

        for match in matches {
            let range = match.range
            if range.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                segments.append(TextSegment(text: before, resolvedPath: nil, isDirectory: false))
            }

            let pathStr = nsText.substring(with: range)
            let resolved: String
            if pathStr.hasPrefix("/") {
                resolved = pathStr
            } else if !workspacePath.isEmpty {
                resolved = (workspacePath as NSString).appendingPathComponent(pathStr)
            } else {
                resolved = pathStr
            }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
                segments.append(TextSegment(text: pathStr, resolvedPath: resolved, isDirectory: isDir.boolValue))
            } else {
                segments.append(TextSegment(text: pathStr, resolvedPath: nil, isDirectory: false))
            }

            lastEnd = range.location + range.length
        }

        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
            segments.append(TextSegment(text: remaining, resolvedPath: nil, isDirectory: false))
        }

        return segments
    }
}

// MARK: - Resizable Divider

struct ResizeDivider: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Stanford.lagunita.opacity(0.4) : Stanford.fog)
            .frame(height: 6)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isDragging ? Stanford.lagunita : Stanford.coolGrey.opacity(0.4))
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let newHeight = height + value.translation.height
                        height = min(maxHeight, max(minHeight, newHeight))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
