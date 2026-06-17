import Foundation
import Testing
@testable import ASTRA

/// Slice 5b: the form-field schema extension (WorkspaceAppViewSpec.formFields) + its validation.
/// The builder that generates forms from REDCap metadata is tested separately; these lock the
/// schema's Codable behavior + the validator rules it relies on.
@Suite("Workspace App Form Schema (Slice 5b)")
struct WorkspaceAppFormSchemaTests {
    /// A valid manifest with an `enrollment` draft table and a `form` view carrying `fields`.
    private static func formManifest(_ fields: [WorkspaceAppFormFieldSpec]) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "enrollment", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "patient_name", type: "text", required: true),
                WorkspaceAppStorageColumn(name: "age", type: "integer"),
                WorkspaceAppStorageColumn(name: "consent", type: "text")
            ])
        ])
        manifest.actions = []
        manifest.automations = []
        manifest.views = [
            WorkspaceAppViewSpec(id: "entry", type: "form", title: "Entry", table: "enrollment", formFields: fields)
        ]
        return manifest
    }

    private static let validFields: [WorkspaceAppFormFieldSpec] = [
        WorkspaceAppFormFieldSpec(name: "patient_name", label: "Name", fieldType: "text", required: true),
        WorkspaceAppFormFieldSpec(name: "age", label: "Age", fieldType: "number", visibleWhen: "[consent] = '1'"),
        WorkspaceAppFormFieldSpec(
            name: "consent", label: "Consent", fieldType: "choice", required: true,
            choices: [WorkspaceAppFormChoice(value: "1", label: "Yes"), WorkspaceAppFormChoice(value: "0", label: "No")]
        )
    ]

    // MARK: - Codable

    @Test("form fields round-trip through JSON")
    func formFieldsRoundTrip() throws {
        let manifest = Self.formManifest(Self.validFields)
        let data = try WorkspaceAppService.encodeManifest(manifest)
        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        #expect(decoded == manifest)
        let field = try #require(decoded.views.first?.formFields.first { $0.name == "consent" })
        #expect(field.choices?.count == 2)
        #expect(field.choices?.first?.label == "Yes")
    }

    @Test("a manifest with no form fields encodes WITHOUT a formFields key (digest stability)")
    func emptyFormFieldsAreOmitted() throws {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let json = String(data: try WorkspaceAppService.encodeManifest(manifest), encoding: .utf8) ?? ""
        #expect(!json.contains("formFields"))
    }

    @Test("a choice field decodes a label-less choice by falling back to the value")
    func choiceLabelFallback() throws {
        let json = #"{"value":"7"}"#.data(using: .utf8)!
        let choice = try JSONDecoder().decode(WorkspaceAppFormChoice.self, from: json)
        #expect(choice.value == "7")
        #expect(choice.label == "7")
    }

    // MARK: - Validation

    @Test("a well-formed form view validates")
    func validFormViewPasses() {
        #expect(WorkspaceAppManifestValidator.validate(Self.formManifest(Self.validFields)).isValid)
    }

    @Test("an unsupported field type is rejected")
    func unknownFieldTypeRejected() {
        let report = WorkspaceAppManifestValidator.validate(Self.formManifest([
            WorkspaceAppFormFieldSpec(name: "patient_name", label: "Name", fieldType: "richtext")
        ]))
        #expect(report.blockers.contains { $0.path.hasSuffix("/fieldType") })
    }

    @Test("a choice field with no choices is rejected")
    func choiceWithoutChoicesRejected() {
        let report = WorkspaceAppManifestValidator.validate(Self.formManifest([
            WorkspaceAppFormFieldSpec(name: "consent", label: "Consent", fieldType: "choice")
        ]))
        #expect(report.blockers.contains { $0.path.hasSuffix("/choices") })
    }

    @Test("a field with no backing draft-table column is rejected")
    func fieldWithoutColumnRejected() {
        let report = WorkspaceAppManifestValidator.validate(Self.formManifest([
            WorkspaceAppFormFieldSpec(name: "ghost_field", label: "Ghost", fieldType: "text")
        ]))
        #expect(report.blockers.contains { $0.message.contains("no matching column") })
    }

    @Test("unsupported branching in visibleWhen is rejected (cannot honor it exactly)")
    func unsupportedVisibleWhenRejected() {
        let report = WorkspaceAppManifestValidator.validate(Self.formManifest([
            WorkspaceAppFormFieldSpec(
                name: "age", label: "Age", fieldType: "number",
                visibleWhen: "datediff([dob], 'today', 'y') > 18"
            )
        ]))
        #expect(report.blockers.contains { $0.path.hasSuffix("/visibleWhen") })
    }

    @Test("safe branching in visibleWhen passes")
    func safeVisibleWhenPasses() {
        let report = WorkspaceAppManifestValidator.validate(Self.formManifest([
            WorkspaceAppFormFieldSpec(name: "age", label: "Age", fieldType: "number", visibleWhen: "[consent] = '1'")
        ]))
        #expect(report.isValid)
    }
}
