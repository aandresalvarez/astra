import Foundation
import Testing
@testable import ASTRA

@Suite("Runtime supervision assessment decoding")
struct RuntimeSupervisionAssessmentTests {
    private let assessment = #"{"assessment":"suspectedStalled","explanation":"No output or file changes during the quiet interval.","evidenceIDs":["runtime","files"]}"#

    @Test("A real Claude response may wrap otherwise valid assessment JSON in one Markdown fence",
          arguments: ["```json\n", "```\n", "```json\r\n"])
    func fencedAssessment(opening: String) {
        let decoded = RuntimeSupervisionAssessment.decode(" \n" + opening + assessment + "\n```\n")
        #expect(decoded?.assessment == .suspectedStalled)
        #expect(decoded?.evidenceIDs == ["runtime", "files"])
    }

    @Test("Fence handling never extracts JSON from prose, multiple blocks or incomplete wrappers",
          arguments: [0, 1, 2, 3, 4, 5])
    func rejectsAmbiguousWrappers(example: Int) {
        let cases = [
            "Explanation first\n```json\n" + assessment + "\n```",
            "```json\n" + assessment + "\n```\nExplanation after",
            "```json\n" + assessment + "\n```\n```json\n" + assessment + "\n```",
            "```json\n" + assessment,
            "```javascript\n" + assessment + "\n```",
            "```json" + assessment + "```"
        ]
        #expect(RuntimeSupervisionAssessment.decode(cases[example]) == nil)
    }

    @Test("Fenced output retains the schema and total response size limits")
    func fencedLimits() {
        let invented = assessment.replacingOccurrences(of: "runtime", with: "invented")
        #expect(RuntimeSupervisionAssessment.decode("```json\n" + invented + "\n```") == nil)
        let oversized = "```json\n" + String(repeating: " ", count: 4_096) + assessment + "\n```"
        #expect(RuntimeSupervisionAssessment.decode(oversized) == nil)
    }
}
