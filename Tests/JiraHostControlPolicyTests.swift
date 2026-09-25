import Testing
@testable import HostControlToolSupport

@Suite("Jira host-control policy")
struct JiraHostControlPolicyTests {
    @Test("get_comments validates and maps the zero-based offset")
    func getCommentsMapsStartAt() throws {
        let request = try JiraRequestPolicy.readRequest(operation: "get_comments", arguments: [
            "issue_key": "ASTRA-123",
            "max_results": 5,
            "start_at": 40
        ])

        #expect(request.method == "GET")
        #expect(request.path == "/rest/api/3/issue/ASTRA-123/comment")
        #expect(request.queryItems.first { $0.name == "startAt" }?.value == "40")
        #expect(request.queryItems.first { $0.name == "maxResults" }?.value == "5")
        #expect(request.queryItems.first { $0.name == "orderBy" }?.value == "created")
    }

    @Test("get_comments rejects negative and non-integer offsets")
    func getCommentsRejectsInvalidStartAt() {
        for invalidValue: Any in [-1, 1.5, "2", true] {
            #expect(throws: JiraRequestPolicyError.self) {
                try JiraRequestPolicy.readRequest(operation: "get_comments", arguments: [
                    "issue_key": "ASTRA-123",
                    "start_at": invalidValue
                ])
            }
        }
    }

    @Test("comment pagination marker identifies the next required page")
    func commentPaginationMarker() {
        let incomplete = #"{"total":25,"comments":[{"id":"1"},{"id":"2"}]}"#
        #expect(JiraCommentPagination.marker(body: incomplete, requestedStartAt: 20)
            == "comments_complete: false\nnext_start_at: 22")

        let complete = #"{"total":22,"comments":[{"id":"1"},{"id":"2"}]}"#
        #expect(JiraCommentPagination.marker(body: complete, requestedStartAt: 20) == nil)
    }
}
