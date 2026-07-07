import Foundation
import Testing
@testable import ASTRA

/// Slice 5b: the form presentation builder evaluates field visibility against the draft using the
/// same Slice 5a branching analyzer, and carries read-only / choices / value through to the UI.
@Suite("Workspace App Form Presentation Builder (Slice 5b)")
struct WorkspaceAppFormPresentationBuilderTests {
    private func view(_ fields: [WorkspaceAppFormFieldSpec]) -> WorkspaceAppViewSpec {
        WorkspaceAppViewSpec(id: "form", type: "form", title: "Form", table: "draft", formFields: fields)
    }

    private func names(_ fields: [WorkspaceAppFormFieldSpec], _ draft: [String: WorkspaceAppStorageValue]) -> [String] {
        WorkspaceAppFormPresentationBuilder.presentation(view: view(fields), draft: draft).map(\.name)
    }

    @Test("a field with no branching is always shown")
    func noBranchingAlwaysShown() {
        let fields = [WorkspaceAppFormFieldSpec(name: "first_name", label: "Name", fieldType: "text")]
        #expect(names(fields, [:]) == ["first_name"])
    }

    @Test("equality branching shows or hides the field")
    func equalityBranching() {
        let fields = [
            WorkspaceAppFormFieldSpec(name: "consent", label: "Consent", fieldType: "yesno"),
            WorkspaceAppFormFieldSpec(name: "dose", label: "Dose", fieldType: "number", visibleWhen: "[consent] = '1'")
        ]
        #expect(names(fields, ["consent": .text("1")]).contains("dose"))
        #expect(!names(fields, ["consent": .text("0")]).contains("dose"))
    }

    @Test("numeric comparison branching evaluates numerically")
    func numericBranching() {
        let fields = [WorkspaceAppFormFieldSpec(name: "guardian", label: "Guardian", fieldType: "text", visibleWhen: "[age] < '18'")]
        #expect(names(fields, ["age": .integer(16)]) == ["guardian"])
        #expect(names(fields, ["age": .integer(40)]).isEmpty)
    }

    @Test("an AND chain requires every clause")
    func andChain() {
        let fields = [WorkspaceAppFormFieldSpec(name: "x", label: "X", fieldType: "text", visibleWhen: "[a] = '1' and [b] = '2'")]
        #expect(names(fields, ["a": .text("1"), "b": .text("2")]) == ["x"])
        #expect(names(fields, ["a": .text("1"), "b": .text("9")]).isEmpty)
    }

    @Test("an OR chain requires any clause")
    func orChain() {
        let fields = [WorkspaceAppFormFieldSpec(name: "x", label: "X", fieldType: "text", visibleWhen: "[a] = '1' or [b] = '2'")]
        #expect(names(fields, ["a": .text("9"), "b": .text("2")]) == ["x"])
        #expect(names(fields, ["a": .text("9"), "b": .text("9")]).isEmpty)
    }

    @Test("a yes/no draft stored as a bool matches a '1' branching clause")
    func boolDraftMatchesYesNo() {
        let fields = [
            WorkspaceAppFormFieldSpec(name: "agree", label: "Agree", fieldType: "yesno"),
            WorkspaceAppFormFieldSpec(name: "detail", label: "Detail", fieldType: "text", visibleWhen: "[agree] = '1'")
        ]
        #expect(names(fields, ["agree": .bool(true)]).contains("detail"))
        #expect(!names(fields, ["agree": .bool(false)]).contains("detail"))
    }

    @Test("read-only, choices, and current value carry into the presentation")
    func readOnlyChoicesAndValue() throws {
        let fields = [
            WorkspaceAppFormFieldSpec(
                name: "consent", label: "Consent", fieldType: "choice", required: true,
                choices: [WorkspaceAppFormChoice(value: "1", label: "Yes")],
                readOnly: true, readOnlyReason: "Unsupported branching: x"
            )
        ]
        let presentation = WorkspaceAppFormPresentationBuilder.presentation(
            view: view(fields), draft: ["consent": .text("1")]
        )
        let field = try #require(presentation.first)
        #expect(field.readOnly)
        #expect(field.readOnlyReason == "Unsupported branching: x")
        #expect(field.required)
        #expect(field.choices.first?.label == "Yes")
        #expect(field.value == .text("1"))
    }
}
