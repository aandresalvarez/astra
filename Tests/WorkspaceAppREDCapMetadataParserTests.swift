import Foundation
import Testing
@testable import ASTRA

/// The local REDCap schema→form bridge: parse raw metadata rows into field metadata,
/// then hand them to the (already tested) form builder. Verified with a sample fixture —
/// no live REDCap project needed (the read that produces these rows is connector-gated).
@Suite("Workspace App REDCap Metadata Parser")
struct WorkspaceAppREDCapMetadataParserTests {
    private func row(_ pairs: [String: String]) -> [String: WorkspaceAppStorageValue] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, WorkspaceAppStorageValue.text($0.value)) })
    }

    private func fixtureRows() -> [[String: WorkspaceAppStorageValue]] {
        [
            row(["field_name": "record_id", "field_type": "text", "required_field": "y", "field_label": "Record ID"]),
            row(["field_name": "age", "field_type": "text", "text_validation_type_or_show_slider_number": "integer",
                 "field_label": "Age", "required_field": "y"]),
            row(["field_name": "sex", "field_type": "radio", "select_choices_or_calculations": "1, Male | 2, Female",
                 "field_label": "Sex"]),
            row(["field_name": "consent", "field_type": "yesno", "field_label": "Consent", "branching_logic": "[age] > 17"]),
            row(["field_name": "", "field_type": "text"]),  // no field_name → dropped
        ]
    }

    @Test("maps REDCap metadata columns into field metadata")
    func parsesMetadataColumns() {
        let fields = WorkspaceAppREDCapMetadataParser.parse(rows: fixtureRows())
        #expect(fields.count == 4)  // the nameless row is dropped
        let age = fields.first { $0.fieldName == "age" }
        #expect(age?.required == true)
        #expect(age?.validation == "integer")
        #expect(fields.first { $0.fieldName == "sex" }?.choices == "1, Male | 2, Female")
        #expect(fields.first { $0.fieldName == "consent" }?.branchingLogic == "[age] > 17")
    }

    @Test("parsed metadata feeds the form builder into a real form manifest")
    func parsedMetadataBuildsForm() {
        let fields = WorkspaceAppREDCapMetadataParser.parse(rows: fixtureRows())
        let manifest = WorkspaceAppREDCapFormBuilder.build(
            appID: "enroll", appName: "Enrollment", formName: "enrollment", fields: fields
        )
        #expect(manifest.views.contains { $0.type == "form" })
    }
}
