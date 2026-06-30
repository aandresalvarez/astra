import Foundation

/// Slice 5b: turns REDCap field metadata into a Workspace App data-entry form manifest (spec §3.2).
/// Native form screens, required + type validation, choice lists, and branching ONLY where the
/// Slice 5a analyzer can honor it exactly — unsupported branching locks the field read-only and
/// records a manifest-level `submitBlockedReasons` so a published form cannot silently mis-render
/// hidden logic. Drafts are stored locally; submit goes through the declared write mode under
/// approval. REDCap remains the system of record (the record key is collected, never minted).
///
/// Pure + deterministic: no I/O, no UUID/clock.
enum WorkspaceAppREDCapFormBuilder {
    static func build(
        appID: String,
        appName: String,
        formName: String,
        fields: [WorkspaceAppREDCapFieldMetadata]
    ) -> WorkspaceAppManifest {
        let draftTable = "\(formName)_draft"

        // REDCap's record key — collected by the form, NOT minted (REDCap owns identity).
        var columns: [WorkspaceAppStorageColumn] = [
            WorkspaceAppStorageColumn(name: "record_id", type: "text", primaryKey: true, required: true)
        ]
        var formFields: [WorkspaceAppFormFieldSpec] = []
        var blockedReasons: [String] = []

        for field in fields where isSupportedEditable(field.fieldType) {
            let fieldType = manifestFieldType(field.fieldType, validation: field.validation)
            let isChoice = fieldType == "choice" || fieldType == "multichoice"
            let choices = isChoice ? WorkspaceAppREDCapChoiceParser.parse(field.choices) : []

            // A choice field with no parseable options can't render — skip it, but record why.
            if isChoice && choices.isEmpty {
                blockedReasons.append("Field '\(field.fieldName)': choice field has no options.")
                continue
            }

            columns.append(WorkspaceAppStorageColumn(
                name: field.fieldName,
                type: storageColumnType(field.fieldType, validation: field.validation),
                required: field.required
            ))

            var spec = WorkspaceAppFormFieldSpec(
                name: field.fieldName,
                label: field.fieldLabel ?? field.fieldName,
                fieldType: fieldType,
                required: field.required,
                choices: isChoice ? choices : nil
            )
            applyBranching(field.branchingLogic, to: &spec, blockedReasons: &blockedReasons)
            formFields.append(spec)
        }

        let blocked = !blockedReasons.isEmpty
        return WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: appID,
                name: appName,
                icon: "square.and.pencil",
                description: "REDCap data-entry form: \(formName)",
                tags: ["form", "redcap", "data-entry"],
                archetypes: ["Data Entry Form"]
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "formSchema", contract: "formSchema.read",
                    operations: ["describeForms", "describeFields", "describeBranchingRules"],
                    providerHint: "redcap", dataClass: "clinical"
                ),
                WorkspaceAppRequirement(
                    id: "recordRead", contract: "recordProject.read",
                    operations: ["readRecords", "validateRecord"], providerHint: "redcap"
                ),
                WorkspaceAppRequirement(
                    id: "recordWrite", contract: "recordProject.write",
                    operations: ["prepareCreate", "validateWrite", "submitCreate"], providerHint: "redcap"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: draftTable, columns: columns)
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "\(formName)_schema", requirementRef: "formSchema",
                    operation: "describeFields", mode: "read"
                )
            ],
            views: [
                WorkspaceAppViewSpec(id: "\(formName)_form", type: "form", title: formName, table: draftTable, formFields: formFields),
                WorkspaceAppViewSpec(id: "\(formName)_review", type: "review", title: "Review \(formName)", table: draftTable)
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "\(formName)_submit",
                    type: "capability.write",
                    label: "Submit",
                    requirementRef: "recordWrite",
                    operation: "submitCreate",
                    table: draftTable,
                    approvalPrompt: "Submit this record to REDCap?",
                    approvalDecisions: ["Submit", "Cancel"],
                    agentRequiresApproval: true
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["formSchema.read", "recordProject.read"],
                writes: [],
                externalWrites: ["recordProject.write"],
                // A blocked form is read-only pending review; otherwise external submit needs approval.
                defaultMode: blocked ? .readOnly : .approvalRequired
            ),
            submitBlockedReasons: blocked ? blockedReasons : nil
        )
    }

    // MARK: - Branching

    private static func applyBranching(
        _ logic: String?,
        to spec: inout WorkspaceAppFormFieldSpec,
        blockedReasons: inout [String]
    ) {
        guard let logic, !logic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch WorkspaceAppREDCapBranchingAnalyzer.classify(logic) {
        case .safe(let condition):
            if !condition.isAlwaysVisible { spec.visibleWhen = logic }  // keep the raw, safe-verified string
        case .unsupported(let reason):
            spec.readOnly = true
            spec.readOnlyReason = "Unsupported branching: \(reason)"
            blockedReasons.append("Field '\(spec.name)': \(reason)")
        }
    }

    // MARK: - Type mapping (conservative)

    private static func isSupportedEditable(_ redcapType: String) -> Bool {
        switch redcapType {
        case "text", "notes", "radio", "dropdown", "checkbox", "yesno", "truefalse":
            return true
        default:
            return false  // descriptive, calc, file, slider, unknown -> dropped (no field, no column)
        }
    }

    private static func manifestFieldType(_ redcapType: String, validation: String?) -> String {
        switch redcapType {
        case "notes": return "textarea"
        case "radio", "dropdown": return "choice"
        case "checkbox": return "multichoice"
        case "yesno", "truefalse": return "yesno"
        case "text":
            switch validationKind(validation) {
            case .integer, .number: return "number"
            case .date, .datetime: return "date"
            case .none: return "text"
            }
        default: return "text"
        }
    }

    private static func storageColumnType(_ redcapType: String, validation: String?) -> String {
        switch redcapType {
        case "yesno", "truefalse": return "bool"
        case "text":
            switch validationKind(validation) {
            case .integer: return "integer"
            case .number: return "real"
            case .date: return "date"
            case .datetime: return "text"  // no native datetime column -> ISO string
            case .none: return "text"
            }
        default: return "text"  // notes / radio / dropdown / checkbox
        }
    }

    private enum ValidationKind { case integer, number, date, datetime, none }

    private static func validationKind(_ validation: String?) -> ValidationKind {
        guard let raw = validation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .none
        }
        if raw == "integer" { return .integer }
        if raw == "number" || raw == "float" { return .number }
        if raw.hasPrefix("date_") { return .date }
        if raw.hasPrefix("datetime") || raw.hasPrefix("time") { return .datetime }
        return .none
    }
}
