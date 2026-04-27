import Testing
import Foundation
@testable import ASTRA

private struct TestTaskSpec: Codable {
    var title: String
    var goal: String
    var inputs: [String]
    var constraints: [String]
    var acceptanceCriteria: [String]
    var estimatedComplexity: String
    var clarifications: [String]?
}

private func extractJSON(from text: String) -> String {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("```") {
        if let start = cleaned.firstIndex(of: "\n") {
            cleaned = String(cleaned[cleaned.index(after: start)...])
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return cleaned
}

@Suite("Spec Engine")
struct SpecEngineTests {

    @Test("JSON extraction strips markdown fences")
    func stripMarkdownFences() {
        let wrapped = "```json\n{\"title\": \"test\"}\n```"
        #expect(extractJSON(from: wrapped) == "{\"title\": \"test\"}")
    }

    @Test("JSON extraction passes plain JSON through")
    func plainJSONPassthrough() {
        let plain = "{\"title\": \"test\"}"
        #expect(extractJSON(from: plain) == "{\"title\": \"test\"}")
    }

    @Test("TaskSpec decoding from valid JSON")
    func validSpecDecoding() throws {
        let json = """
        {"title":"Add dark mode","goal":"Implement dark mode toggle","inputs":[],"constraints":["Don't break existing styles"],"acceptanceCriteria":["Toggle works"],"estimatedComplexity":"medium"}
        """
        let spec = try JSONDecoder().decode(TestTaskSpec.self, from: json.data(using: .utf8)!)
        #expect(spec.title == "Add dark mode")
        #expect(spec.estimatedComplexity == "medium")
        #expect(spec.constraints.count == 1)
    }

    @Test("TaskSpec normalizes non-enum complexity labels")
    func taskSpecNormalizesComplexity() throws {
        let json = """
        {"title":"Add dark mode","goal":"Implement dark mode toggle","inputs":[],"constraints":[],"acceptanceCriteria":[],"estimatedComplexity":"low-medium"}
        """
        let spec = try JSONDecoder().decode(TestTaskSpec.self, from: json.data(using: .utf8)!)
        let productionSpec = try JSONDecoder().decode(TaskSpec.self, from: json.data(using: .utf8)!)
        #expect(spec.estimatedComplexity == "low-medium")
        #expect(productionSpec.estimatedComplexity == "medium")
    }

    @Test("TaskSpec decodes object-shaped list fields")
    func taskSpecDecodesObjectShapedLists() throws {
        let json = """
        {"title":"Add dark mode","goal":"Implement dark mode toggle","inputs":{"files":["SettingsView.swift"],"context":"preferences"},"constraints":"Keep current design","acceptanceCriteria":{"ui":"Toggle appears","behavior":"Selection persists"},"estimatedComplexity":"medium-high"}
        """
        let spec = try JSONDecoder().decode(TaskSpec.self, from: json.data(using: .utf8)!)
        #expect(spec.inputs.contains("context: preferences"))
        #expect(spec.inputs.contains("files: SettingsView.swift"))
        #expect(spec.constraints == ["Keep current design"])
        #expect(spec.acceptanceCriteria.contains("behavior: Selection persists"))
        #expect(spec.estimatedComplexity == "high")
    }

    @Test("TaskSpec with clarifications")
    func specWithClarifications() throws {
        let json = """
        {"title":"Fix bug","goal":"Fix the bug","inputs":[],"constraints":[],"acceptanceCriteria":[],"estimatedComplexity":"low","clarifications":["Which bug?","What file?"]}
        """
        let spec = try JSONDecoder().decode(TestTaskSpec.self, from: json.data(using: .utf8)!)
        #expect(spec.clarifications?.count == 2)
        #expect(spec.clarifications?.first == "Which bug?")
    }

    @Test("TaskSpec without clarifications is nil")
    func specWithoutClarifications() throws {
        let json = """
        {"title":"Test","goal":"Test","inputs":[],"constraints":[],"acceptanceCriteria":[],"estimatedComplexity":"low"}
        """
        let spec = try JSONDecoder().decode(TestTaskSpec.self, from: json.data(using: .utf8)!)
        #expect(spec.clarifications == nil)
    }

    @Test("Max retries constant is 2")
    func maxRetriesValue() {

        #expect(SpecEngine.maxRetries == 2)
    }

    @Test("JSON schema contains all required fields")
    func jsonSchemaFields() {

        let schema = SpecEngine.jsonSchema
        #expect(schema.contains("title"))
        #expect(schema.contains("goal"))
        #expect(schema.contains("inputs"))
        #expect(schema.contains("constraints"))
        #expect(schema.contains("acceptanceCriteria"))
        #expect(schema.contains("estimatedComplexity"))
        #expect(schema.contains("clarifications"))
    }

    @Test("Extraction prompt includes schema")
    func extractionPromptIncludesSchema() {

        let prompt = SpecEngine.extractionPrompt
        #expect(prompt.contains("Schema:"))
        #expect(prompt.contains("No other text"))
        #expect(prompt.contains("no markdown fences"))
    }

    @Test("JSON extraction handles nested fences")
    func nestedFences() {
        let wrapped = "```\n{\"title\": \"test\"}\n```"
        #expect(extractJSON(from: wrapped) == "{\"title\": \"test\"}")
    }

    @Test("JSON extraction handles extra whitespace")
    func extraWhitespace() {
        let padded = "  \n  {\"title\": \"test\"}  \n  "
        #expect(extractJSON(from: padded) == "{\"title\": \"test\"}")
    }
}
