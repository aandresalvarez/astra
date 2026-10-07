import SwiftUI

/// What the chat shows for an action ASTRA took outside the machine.
///
/// A state row, not a card: it sits in the conversation like a system note,
/// leads with what was done, keeps where it happened as metadata, and opens the
/// result when it has a link. Only the exceptional provenance gets a pill —
/// "Auto" when no one was asked, "Agent" when ASTRA only observed it — because
/// a reviewed action is the normal case and needs no badge.
struct ExternalActionRecordRow: View {
    let record: ExternalActionRecord

    var body: some View {
        // `.top`, not `.firstTextBaseline`: see `timelineEventRow` in TaskMainView.
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: ExternalActionRecordPresentation.symbolName(for: record.kind))
                .font(Stanford.ui(11, weight: .medium))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 14)
                .padding(.top, 2)
            title
            Text(record.destination)
                .font(Stanford.chatMeta(12))
                .foregroundStyle(Stanford.coolGrey)
                .lineLimit(1)
                .truncationMode(.middle)
            if let pill = ExternalActionRecordPresentation.provenancePill(for: record.authorization) {
                Text(pill)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: Stanford.chatParagraphMaxWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ExternalActionRecordPresentation.accessibilityLabel(for: record))
        .accessibilityIdentifier("ExternalActionRecord")
    }

    @ViewBuilder
    private var title: some View {
        if let url = record.url {
            Link(destination: url) {
                Text(record.title)
                    .font(Stanford.chatMeta(12).weight(.medium))
                    .foregroundStyle(Stanford.link)
            }
            .help(url.absoluteString)
        } else {
            Text(record.title)
                .font(Stanford.chatMeta(12).weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

enum ExternalActionRecordPresentation {
    static func symbolName(for kind: ExternalActionKind) -> String {
        switch kind {
        case .connectorCredentialUse: "key"
        case .connectorMutation: "ticket"
        case .gitPullRequestPublication: "arrow.triangle.pull"
        case .githubReviewPublication, .githubThreadReply: "text.bubble"
        case .githubThreadResolution: "checkmark.bubble"
        }
    }

    static func provenancePill(for authorization: ExternalActionAuthorization) -> String? {
        switch authorization {
        case .autoPolicy: "Auto"
        case .agentObserved: "Agent"
        case .userReviewed, .userGrantedForTask: nil
        }
    }

    static func accessibilityLabel(for record: ExternalActionRecord) -> String {
        var parts = ["Done outside ASTRA: \(record.title)", record.destination]
        switch record.authorization {
        case .autoPolicy: parts.append("done by Auto without asking")
        case .agentObserved: parts.append("done by the agent")
        case .userReviewed, .userGrantedForTask: parts.append("approved by you")
        }
        return parts.joined(separator: ", ")
    }
}
