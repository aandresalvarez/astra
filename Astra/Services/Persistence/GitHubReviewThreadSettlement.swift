import Foundation

/// Which dispatched GitHub review-thread batches are still unsettled. The one owner of that
/// rule: the app's pending-work gate and the recovery mirror's retention both read it, so a
/// batch completion treats as done is never kept as live recovery evidence, and the reverse.
///
/// It reads the thread records as JSON because the record types live in the app target.
public enum GitHubReviewThreadSettlement {
    public struct Record {
        public let type: String
        public let payload: String
        public let timestamp: Date

        public init(type: String, payload: String, timestamp: Date) {
            self.type = type; self.payload = payload; self.timestamp = timestamp
        }
    }

    static let dispatched = "github.review-threads.dispatched"
    static let actionReceipt = "github.review-threads.action-receipt"
    static let finalTypes: Set<String> = ["github.review-threads.receipt", "github.review-threads.receipt-recovery"]

    /// A dispatch is settled by its final receipt, by the settled mark the mirror leaves on a
    /// compacted dispatch, or when every action its approved payload required is confirmed by
    /// an action receipt for the same pull request recorded at or after the dispatch: its own,
    /// or one of a later proposal sent to finish it. A confirmation older than the dispatch
    /// belongs to earlier work and cannot settle it.
    public static func unsettledProposalIDs(_ records: [Record]) -> Set<String> {
        func object(_ record: Record) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(record.payload.utf8))) as? [String: Any]
        }
        var finals = Set<String>()
        var confirmations: [(pullRequest: String, at: Date, action: String)] = []
        var dispatches: [(proposalID: String, pullRequest: String, at: Date, object: [String: Any])] = []
        for record in records {
            guard let object = object(record), let proposalID = object["proposalID"] as? String else { continue }
            let pullRequest = object["pullRequestURL"] as? String ?? ""
            if finalTypes.contains(record.type) {
                finals.insert(proposalID)
            } else if record.type == actionReceipt {
                for action in (object["actions"] as? [[String: Any]]) ?? [] {
                    guard let thread = action["threadID"] as? String, let operation = action["operation"] as? String else { continue }
                    confirmations.append((pullRequest, record.timestamp, "\(thread):\(operation)"))
                }
            } else if record.type == dispatched {
                dispatches.append((proposalID, pullRequest, record.timestamp, object))
            }
        }
        var unsettled = Set<String>()
        for dispatch in dispatches where !finals.contains(dispatch.proposalID) && dispatch.object["settled"] as? Bool != true {
            let done = Set(confirmations.filter { $0.pullRequest == dispatch.pullRequest && $0.at >= dispatch.at }.map(\.action))
            guard let required = requiredActions(dispatch.object), !required.isEmpty, required.allSatisfy(done.contains) else {
                unsettled.insert(dispatch.proposalID)
                continue
            }
        }
        return unsettled
    }

    /// The approved payload's actions ("THREAD:reply", "THREAD:resolve"), or the summary a
    /// compacted dispatch keeps in its place.
    static func requiredActions(_ dispatch: [String: Any]) -> [String]? {
        if let approved = dispatch["approvedPayload"] as? [String: Any] {
            return ((approved["threads"] as? [[String: Any]]) ?? []).flatMap { thread -> [String] in
                guard let id = thread["threadId"] as? String else { return [] }
                return (thread["reply"] is String ? ["\(id):reply"] : []) + (thread["resolve"] as? Bool == true ? ["\(id):resolve"] : [])
            }
        }
        return dispatch["requiredActions"] as? [String]
    }
}
