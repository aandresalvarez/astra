import Foundation

/// Maps raw REDCap metadata rows (the column names REDCap's `metadata`/`describeFields`
/// export returns — field_name, field_label, field_type, required_field,
/// select_choices_or_calculations, text_validation_type_or_show_slider_number,
/// branching_logic) into `[WorkspaceAppREDCapFieldMetadata]`, which
/// `WorkspaceAppREDCapFormBuilder` turns into a safe native data-entry form.
///
/// Pure + value-typed: fully testable with a sample metadata fixture, no live REDCap
/// project needed. It is the deterministic bridge between a `formSchema.read` capability
/// read (connector-gated) and the already-tested form builder.
enum WorkspaceAppREDCapMetadataParser {
    static func parse(rows: [[String: WorkspaceAppStorageValue]]) -> [WorkspaceAppREDCapFieldMetadata] {
        rows.compactMap { row in
            let name = string(row, "field_name")
            guard !name.isEmpty else { return nil }
            let type = string(row, "field_type")
            return WorkspaceAppREDCapFieldMetadata(
                fieldName: name,
                fieldLabel: optional(row, "field_label"),
                fieldType: type.isEmpty ? "text" : type,
                required: string(row, "required_field").lowercased() == "y",
                choices: optional(row, "select_choices_or_calculations"),
                validation: optional(row, "text_validation_type_or_show_slider_number"),
                branchingLogic: optional(row, "branching_logic")
            )
        }
    }

    private static func string(_ row: [String: WorkspaceAppStorageValue], _ key: String) -> String {
        WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[key])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optional(_ row: [String: WorkspaceAppStorageValue], _ key: String) -> String? {
        let value = string(row, key)
        return value.isEmpty ? nil : value
    }
}
