import Foundation
import Testing
@testable import ASTRA

/// The readable half of a review is derived from the bytes that will be sent, and
/// its one hard rule is that it never shows less than is sent: whatever the body
/// carries that the fields do not explain is named, so a reader who trusts the
/// summary is still told to look.
@Suite("Connector mutation review content")
struct ConnectorMutationReviewContentTests {
    @Test("A comment shows its text and audience, and a marked one says it is internal")
    func commentShowsTextAndAudience() throws {
        let publicFields = try fields("add_comment", ["body": "One\n\nTwo"])
        #expect(value("comment", in: publicFields) == "One\n\nTwo")
        #expect(try #require(value("visibility", in: publicFields)).contains("including the customer"))
        #expect(publicFields.allSatisfy { $0.id != "unexplained-also-sends" })

        let internalFields = try fields("add_comment", [
            "body": "Note",
            "properties": [["key": "sd.public.comment", "value": ["internal": true]]]
        ])
        #expect(try #require(value("visibility", in: internalFields)).contains("Internal only"))

        // Present but not internal is still public — only `internal: true` hides it.
        let notInternal = try fields("add_comment", [
            "body": "Reply",
            "properties": [["key": "sd.public.comment", "value": ["internal": false]]]
        ])
        #expect(try #require(value("visibility", in: notInternal)).contains("including the customer"))
    }

    @Test("Anything a comment body carries beyond text and visibility is named")
    func commentNamesWhatItDoesNotExplain() throws {
        let fields = try fields("add_comment", [
            "body": "x",
            "visibility": ["type": "role", "value": "Administrators"],
            "properties": [
                ["key": "sd.public.comment", "value": ["internal": false]],
                ["key": "evil.flag", "value": true]
            ]
        ])

        let extra = try #require(value("unexplained-also-sends", in: fields))
        #expect(extra.contains("visibility"))
        #expect(extra.contains("properties.evil.flag"))
        // Names, never values: the raw body is on the sheet.
        #expect(!extra.contains("Administrators"))
    }

    @Test("An update lists each change, and what clearing the labels means")
    func updateListsEachChange() throws {
        let fields = try fields("update_issue", ["fields": [
            "summary": "New title",
            "description": "New body",
            "priority": ["name": "High"],
            "labels": [String](),
            "assignee": ["accountId": "5dc098e4a693ee0df50f941c"]
        ]])

        #expect(value("new-summary", in: fields) == "New title")
        #expect(value("new-description", in: fields) == "New body")
        #expect(value("new-priority", in: fields) == "High")
        #expect(value("new-labels", in: fields) == "None — removes every label")
        #expect(value("new-assignee", in: fields) == "5dc098e4a693ee0df50f941c")
        #expect(fields.allSatisfy { !$0.id.hasPrefix("unexplained") })
    }

    @Test("An update names the fields it changes that no line above explains")
    func updateNamesWhatItDoesNotExplain() throws {
        let fields = try fields("update_issue", [
            "fields": ["summary": "t", "security": ["name": "Internal"], "customfield_10010": "x"],
            "update": ["labels": [["add": "x"]]]
        ])

        #expect(value("unexplained-also-changes", in: fields) == "customfield_10010, security")
        #expect(value("unexplained-also-sends", in: fields) == "update")
    }

    @Test("A transition shows its id and resolution")
    func transitionShowsIdAndResolution() throws {
        let fields = try fields("transition_issue", [
            "transition": ["id": "31"],
            "fields": ["resolution": ["name": "Done"], "assignee": ["accountId": "x"]]
        ])

        #expect(value("transition-id", in: fields) == "31")
        #expect(value("resolution", in: fields) == "Done")
        #expect(value("unexplained-also-sets", in: fields) == "assignee")
    }

    @Test("An operation with no readable form, or a body that is not JSON, adds nothing")
    func unknownOperationAddsNothing() throws {
        #expect(try fields("create_issue", ["fields": ["summary": "s"]]).isEmpty)
        #expect(ConnectorMutationReviewContent.fields(operation: "add_comment", requestBody: Data("not json".utf8)).isEmpty)
    }

    private func fields(_ operation: String, _ body: [String: Any]) throws -> [ConnectorMutationReviewField] {
        ConnectorMutationReviewContent.fields(
            operation: operation,
            requestBody: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func value(_ id: String, in fields: [ConnectorMutationReviewField]) -> String? {
        fields.first { $0.id == id }?.value
    }
}
