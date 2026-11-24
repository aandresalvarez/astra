import Foundation

enum RunActivityProgressPhaseStatus: Hashable, Sendable {
    case completed
    case active
    case upcoming
}

struct RunActivityProgressPhasePresentation: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: RunActivityProgressPhaseStatus
}

struct RunActivityProgressTimelinePresentation: Hashable, Sendable {
    static let compactMessageLimit = 3
    static let historyPageSize = 20

    let phases: [RunActivityProgressPhasePresentation]
    let messageAttachmentPhaseID: String?
    let visibleMessages: [TaskRunProgressMessage]
    let hiddenMessageCount: Int
    let totalMessageCount: Int
    let olderMessageCount: Int
    let newerMessageCount: Int
    let latestPageAnchorID: UUID?
    let olderPageAnchorID: UUID?
    let newerPageAnchorID: UUID?
    let isBrowsingHistory: Bool

    init(
        messages: [TaskRunProgressMessage],
        planItems: [TaskProtocolTodoItem],
        historyAnchorID: UUID?
    ) {
        let firstPendingIndex = planItems.firstIndex { !$0.isDone }
        phases = planItems.enumerated().map { index, item in
            let status: RunActivityProgressPhaseStatus
            if item.isDone {
                status = .completed
            } else if index == firstPendingIndex {
                status = .active
            } else {
                status = .upcoming
            }
            return RunActivityProgressPhasePresentation(
                id: item.id,
                title: item.text,
                status: status
            )
        }
        messageAttachmentPhaseID = phases.first(where: { $0.status == .active })?.id
            ?? phases.last?.id

        totalMessageCount = messages.count
        latestPageAnchorID = messages.last?.id
        guard let historyAnchorID, !messages.isEmpty else {
            isBrowsingHistory = false
            visibleMessages = Array(messages.suffix(Self.compactMessageLimit))
            hiddenMessageCount = max(0, messages.count - visibleMessages.count)
            olderMessageCount = hiddenMessageCount
            newerMessageCount = 0
            olderPageAnchorID = nil
            newerPageAnchorID = nil
            return
        }

        isBrowsingHistory = true
        let anchorIndex = messages.firstIndex { $0.id == historyAnchorID } ?? (messages.count - 1)
        let endIndex = anchorIndex + 1
        let startIndex = max(0, endIndex - Self.historyPageSize)
        visibleMessages = Array(messages[startIndex..<endIndex])
        olderMessageCount = startIndex
        newerMessageCount = messages.count - endIndex
        hiddenMessageCount = olderMessageCount + newerMessageCount
        olderPageAnchorID = startIndex > 0 ? messages[startIndex - 1].id : nil
        if endIndex < messages.count {
            let newerEndIndex = min(messages.count, endIndex + Self.historyPageSize)
            newerPageAnchorID = messages[newerEndIndex - 1].id
        } else {
            newerPageAnchorID = nil
        }
    }
}
