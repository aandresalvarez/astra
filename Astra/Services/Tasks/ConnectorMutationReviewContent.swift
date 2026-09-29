import Foundation

/// The readable half of a review: what the request body says, in the words a
/// person reads it in.
///
/// The sheet also prints the body verbatim, and that is the authority — but a
/// support reply is prose, and JSON stores prose with its newlines as `\n`. A
/// user asked to approve two paragraphs of customer-facing text should read two
/// paragraphs, not one escaped string. So the fields here are derived from the
/// exact bytes that will be sent, never from the envelope's own `summary`, and
/// anything in those bytes the readable view does not explain is listed rather
/// than omitted: a review that quietly shows less than is sent is worse than no
/// summary at all.
enum ConnectorMutationReviewContent {
    static func fields(operation: String, requestBody: Data) -> [ConnectorMutationReviewField] {
        guard let object = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any] else {
            return []
        }
        switch operation {
        case "add_comment":
            return comment(object)
        case "update_issue":
            return update(object)
        case "transition_issue":
            return transition(object)
        default:
            return []
        }
    }

    // MARK: - Comment

    private static func comment(_ object: [String: Any]) -> [ConnectorMutationReviewField] {
        var fields: [ConnectorMutationReviewField] = []
        if let text = object["body"] as? String {
            fields.append(field("comment", "Comment", text))
        }
        fields.append(field("visibility", "Visible to", visibility(of: object)))
        // Any property other than the visibility one is something the reader was
        // not told about above, so it is named here alongside stray top-level keys.
        let otherProperties = (object["properties"] as? [[String: Any]] ?? [])
            .map { ($0["key"] as? String) ?? "(unnamed)" }
            .filter { $0 != "sd.public.comment" }
            .map { "properties.\($0)" }
        fields.append(contentsOf: unexplained(
            names: Set(object.keys).subtracting(["body", "properties"]).sorted() + otherProperties,
            label: "Also sends"
        ))
        return fields
    }

    /// The property Jira Service Management reads to decide whether the
    /// customer sees a comment. Absent means public, which is why the sheet
    /// states the audience in either case instead of only flagging the unusual
    /// one.
    private static func visibility(of object: [String: Any]) -> String {
        let properties = object["properties"] as? [[String: Any]] ?? []
        let isInternal = properties.contains { property in
            guard property["key"] as? String == "sd.public.comment",
                  let value = property["value"] as? [String: Any] else { return false }
            return value["internal"] as? Bool == true
        }
        return isInternal
            ? "Internal only — hidden from the customer on a Jira Service Management ticket"
            : "Everyone who can see the ticket — including the customer on a Jira Service Management ticket"
    }

    // MARK: - Update

    private static func update(_ object: [String: Any]) -> [ConnectorMutationReviewField] {
        let changes = object["fields"] as? [String: Any] ?? [:]
        var fields: [ConnectorMutationReviewField] = []
        if let summary = changes["summary"] as? String {
            fields.append(field("new-summary", "New summary", summary))
        }
        if let description = changes["description"] as? String {
            fields.append(field("new-description", "New description", description))
        }
        if let priority = (changes["priority"] as? [String: Any])?["name"] as? String {
            fields.append(field("new-priority", "New priority", priority))
        }
        if let labels = changes["labels"] as? [String] {
            fields.append(field(
                "new-labels",
                "New labels (replaces the current set)",
                labels.isEmpty ? "None — removes every label" : labels.joined(separator: ", ")
            ))
        }
        if let assignee = (changes["assignee"] as? [String: Any])?["accountId"] as? String {
            fields.append(field("new-assignee", "New assignee (account id)", assignee, monospaced: true))
        }
        fields.append(contentsOf: unexplained(
            names: Set(changes.keys).subtracting(["summary", "description", "priority", "labels", "assignee"]).sorted(),
            label: "Also changes"
        ))
        fields.append(contentsOf: unexplained(
            names: Set(object.keys).subtracting(["fields"]).sorted(),
            label: "Also sends"
        ))
        return fields
    }

    // MARK: - Transition

    private static func transition(_ object: [String: Any]) -> [ConnectorMutationReviewField] {
        var fields: [ConnectorMutationReviewField] = []
        if let id = (object["transition"] as? [String: Any])?["id"] as? String {
            fields.append(field("transition-id", "Transition id", id, monospaced: true))
        }
        let changes = object["fields"] as? [String: Any] ?? [:]
        if let resolution = (changes["resolution"] as? [String: Any])?["name"] as? String {
            fields.append(field("resolution", "Resolution", resolution))
        }
        fields.append(contentsOf: unexplained(
            names: Set(changes.keys).subtracting(["resolution"]).sorted(),
            label: "Also sets"
        ))
        fields.append(contentsOf: unexplained(
            names: Set(object.keys).subtracting(["transition", "fields"]).sorted(),
            label: "Also sends"
        ))
        return fields
    }

    // MARK: - Helpers

    /// Names — never values — of what the body carries that the fields above do
    /// not account for. Naming is enough: the verbatim body is on the sheet, and
    /// the point is that the reader is told to look.
    private static func unexplained(names: [String], label: String) -> [ConnectorMutationReviewField] {
        guard !names.isEmpty else { return [] }
        return [field(
            "unexplained-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))",
            label,
            names.joined(separator: ", "),
            monospaced: true
        )]
    }

    private static func field(
        _ id: String,
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> ConnectorMutationReviewField {
        ConnectorMutationReviewField(id: id, label: label, value: value, isMonospaced: monospaced)
    }
}
