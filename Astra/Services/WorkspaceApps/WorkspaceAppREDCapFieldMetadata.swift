import Foundation

/// Slice 5b: the REDCap field metadata the form builder consumes. Mirrors the logical shape of
/// `formSchema.read` / describeFields (the transport hands this over; a mocked transport is fine
/// for the builder). All values are RAW REDCap strings — nothing is trusted pre-parsed; branching
/// is classified by `WorkspaceAppREDCapBranchingAnalyzer`, choices by the parser below.
struct WorkspaceAppREDCapFieldMetadata: Codable, Sendable, Equatable {
    var fieldName: String
    var fieldLabel: String?
    var fieldType: String          // text|notes|radio|dropdown|checkbox|yesno|truefalse|calc|descriptive|file|slider
    var required: Bool
    var choices: String?           // raw REDCap enum string: "1, Yes | 0, No"
    var validation: String?        // raw text_validation_type_or_show_slider_number: integer|number|date_ymd|...
    var branchingLogic: String?    // raw REDCap branching_logic

    init(
        fieldName: String,
        fieldLabel: String? = nil,
        fieldType: String,
        required: Bool = false,
        choices: String? = nil,
        validation: String? = nil,
        branchingLogic: String? = nil
    ) {
        self.fieldName = fieldName
        self.fieldLabel = fieldLabel
        self.fieldType = fieldType
        self.required = required
        self.choices = choices
        self.validation = validation
        self.branchingLogic = branchingLogic
    }
}

/// Parses a REDCap choice string (`"value, Label | value, Label | ..."`) into form choices.
/// Each entry splits on the FIRST comma so labels may contain commas; a label-less entry falls
/// back to its value; malformed/blank entries are dropped.
enum WorkspaceAppREDCapChoiceParser {
    static func parse(_ raw: String?) -> [WorkspaceAppFormChoice] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return raw.split(separator: "|").compactMap { entry -> WorkspaceAppFormChoice? in
            let parts = entry.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !value.isEmpty else { return nil }
            let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : value
            return WorkspaceAppFormChoice(value: value, label: label.isEmpty ? value : label)
        }
    }
}
