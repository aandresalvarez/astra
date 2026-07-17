import SwiftUI

enum RunActivityLayout {
    static let disclosureMinimumHitHeight: CGFloat = 40
    static let disclosureIconHitFrame: CGFloat = 28
    static let tabMinimumHitHeight: CGFloat = 34
    static let progressMessageLineLimit = 4
}

struct RunActivityDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(Stanford.chatMeta())
                .foregroundStyle(Stanford.coolGrey.opacity(0.86))
            content()
        }
        .padding(.vertical, 7)
    }
}

struct RunActivityTabStrip: View {
    let tabs: [RunActivityTabDescriptor]
    let selectedTab: RunActivityTab
    let onSelect: (RunActivityTab) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(tabs) { descriptor in
                    tabButton(descriptor)
                }
                Spacer(minLength: 0)
            }

            Menu {
                ForEach(tabs) { descriptor in
                    Button {
                        onSelect(descriptor.tab)
                    } label: {
                        Label(descriptor.accessibilityLabel, systemImage: descriptor.tab.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: selectedTab.systemImage)
                        .font(Stanford.ui(11))
                    Text("View: \(selectedTab.title)")
                        .font(Stanford.chatSection())
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Stanford.ui(9))
                }
                .foregroundStyle(Stanford.lagunita)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: RunActivityLayout.tabMinimumHitHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Run activity view")
            .accessibilityValue(selectedTab.title)
        }
    }

    private func tabButton(_ descriptor: RunActivityTabDescriptor) -> some View {
        let isSelected = descriptor.tab == selectedTab
        return Button {
            onSelect(descriptor.tab)
        } label: {
            HStack(spacing: 5) {
                Text(descriptor.tab.title)
                    .font(Stanford.chatSection())
                if let count = descriptor.count, count > 0 {
                    Text("\(count)")
                        .font(Stanford.chatMeta(10))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: RunActivityLayout.tabMinimumHitHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Stanford.lagunita : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptor.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct RunActivitySelectedTabView<ToolsContent: View, PolicyContent: View, LogsContent: View>: View {
    let selectedTab: RunActivityTab
    let isRunning: Bool
    let presentation: RunActivityPresentation
    let planItems: [TaskProtocolTodoItem]
    let updateHistoryAnchorID: UUID?
    let onSelectUpdateHistoryAnchor: (UUID?) -> Void
    let onOpenFiles: () -> Void
    private let toolsContent: () -> ToolsContent
    private let policyContent: () -> PolicyContent
    private let logsContent: () -> LogsContent

    init(
        selectedTab: RunActivityTab,
        isRunning: Bool,
        presentation: RunActivityPresentation,
        planItems: [TaskProtocolTodoItem],
        updateHistoryAnchorID: UUID?,
        onSelectUpdateHistoryAnchor: @escaping (UUID?) -> Void,
        onOpenFiles: @escaping () -> Void,
        @ViewBuilder toolsContent: @escaping () -> ToolsContent,
        @ViewBuilder policyContent: @escaping () -> PolicyContent,
        @ViewBuilder logsContent: @escaping () -> LogsContent
    ) {
        self.selectedTab = selectedTab
        self.isRunning = isRunning
        self.presentation = presentation
        self.planItems = planItems
        self.updateHistoryAnchorID = updateHistoryAnchorID
        self.onSelectUpdateHistoryAnchor = onSelectUpdateHistoryAnchor
        self.onOpenFiles = onOpenFiles
        self.toolsContent = toolsContent
        self.policyContent = policyContent
        self.logsContent = logsContent
    }

    @ViewBuilder
    var body: some View {
        switch selectedTab {
        case .updates:
            RunActivityProgressTimelineView(
                presentation: RunActivityProgressTimelinePresentation(
                    messages: presentation.progressMessages,
                    planItems: planItems,
                    historyAnchorID: updateHistoryAnchorID
                ),
                isRunning: isRunning,
                onSelectHistoryAnchor: onSelectUpdateHistoryAnchor
            )
        case .tools:
            toolsContent()
        case .files:
            Button(action: onOpenFiles) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(Stanford.ui(11))
                    Text("\(presentation.files.count) changed \(presentation.files.count == 1 ? "file" : "files")")
                        .font(Stanford.chatSection())
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(Stanford.ui(10))
                }
                .foregroundStyle(Stanford.lagunita)
                .frame(minHeight: RunActivityLayout.tabMinimumHitHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .policy:
            policyContent()
        case .logs:
            logsContent()
        }
    }
}

struct RunActivityProgressTimelineView: View {
    let presentation: RunActivityProgressTimelinePresentation
    let isRunning: Bool
    let onSelectHistoryAnchor: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.phases.isEmpty {
                messageTimeline(presentation.visibleMessages)
            } else {
                phaseTimeline
            }

            historyControls
        }
    }

    private var phaseTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.phases) { phase in
                phaseRow(phase)
                if phase.id == presentation.messageAttachmentPhaseID {
                    if presentation.visibleMessages.isEmpty {
                        if phase.status == .active, isRunning {
                            Text("Waiting for the next progress update…")
                                .font(Stanford.chatMeta())
                                .foregroundStyle(Stanford.textTertiary)
                                .padding(.leading, 34)
                                .padding(.bottom, 8)
                        }
                    } else {
                        messageTimeline(presentation.visibleMessages)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func phaseRow(_ phase: RunActivityProgressPhasePresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: phaseIcon(phase.status))
                .font(Stanford.ui(14))
                .foregroundStyle(phaseColor(phase.status))
                .frame(width: 18, height: 20)
            Text(phase.title)
                .font(Stanford.chatSection(13))
                .foregroundStyle(phase.status == .active ? Stanford.lagunita : Stanford.readingText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(phaseStatusLabel(phase.status))
                .font(Stanford.chatMeta())
                .foregroundStyle(phaseColor(phase.status))
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func messageTimeline(_ messages: [TaskRunProgressMessage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let isCurrent = isRunning && message.id == messages.last?.id
                HStack(alignment: .top, spacing: 9) {
                    VStack(spacing: 0) {
                        Image(systemName: isCurrent ? "circle.inset.filled" : "circle.fill")
                            .font(Stanford.ui(isCurrent ? 12 : 7))
                            .foregroundStyle(isCurrent ? Stanford.lagunita : Stanford.textTertiary)
                            .frame(width: 14, height: 16)
                        if index < messages.count - 1 {
                            Rectangle()
                                .fill(Stanford.sandstone.opacity(0.45))
                                .frame(width: 1)
                                .frame(minHeight: 28)
                        }
                    }

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(Stanford.chatMeta())
                        .foregroundStyle(Stanford.textTertiary)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .leading)

                    Text(message.text)
                        .font(Stanford.chatSection())
                        .foregroundStyle(isCurrent ? Stanford.readingText : Stanford.textSecondary)
                        .lineLimit(RunActivityLayout.progressMessageLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, isCurrent ? 7 : 0)
                .background(isCurrent ? Stanford.lagunita.opacity(0.055) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var historyControls: some View {
        if presentation.isBrowsingHistory {
            HStack(spacing: 14) {
                if let olderAnchorID = presentation.olderPageAnchorID {
                    historyButton(
                        "Older (\(presentation.olderMessageCount))",
                        systemImage: "chevron.left",
                        anchorID: olderAnchorID
                    )
                }
                if let newerAnchorID = presentation.newerPageAnchorID {
                    historyButton(
                        "Newer (\(presentation.newerMessageCount))",
                        systemImage: "chevron.right",
                        anchorID: newerAnchorID
                    )
                }
                Button("Recent only") {
                    onSelectHistoryAnchor(nil)
                }
                .font(Stanford.chatMeta(12))
                .buttonStyle(.plain)
                .foregroundStyle(Stanford.lagunita)
            }
            .padding(.vertical, 7)
        } else if presentation.totalMessageCount > RunActivityProgressTimelinePresentation.compactMessageLimit,
                  let latestAnchorID = presentation.latestPageAnchorID {
            historyButton(
                "Browse all (\(presentation.totalMessageCount))",
                systemImage: "chevron.right",
                anchorID: latestAnchorID
            )
            .padding(.vertical, 7)
        }
    }

    private func historyButton(_ title: String, systemImage: String, anchorID: UUID) -> some View {
        Button {
            onSelectHistoryAnchor(anchorID)
        } label: {
            Label(title, systemImage: systemImage)
                .font(Stanford.chatMeta(12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
    }

    private func phaseIcon(_ status: RunActivityProgressPhaseStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .active: "circle.inset.filled"
        case .upcoming: "circle"
        }
    }

    private func phaseColor(_ status: RunActivityProgressPhaseStatus) -> Color {
        switch status {
        case .completed: Stanford.paloAltoGreen
        case .active: Stanford.lagunita
        case .upcoming: Stanford.textTertiary
        }
    }

    private func phaseStatusLabel(_ status: RunActivityProgressPhaseStatus) -> String {
        switch status {
        case .completed: "Complete"
        case .active: "Current"
        case .upcoming: "Queued"
        }
    }
}
