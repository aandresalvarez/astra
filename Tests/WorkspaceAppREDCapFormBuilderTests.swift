import Foundation
import Testing
@testable import ASTRA

/// Slice 5b: the REDCap-metadata -> form-manifest builder (spec §3.2). Proves field-type/choice/
/// required mapping, the 5a-driven branching safety (safe -> visibleWhen, unsupported -> read-only
/// + submit-block), and that the generated manifest is valid + governed.
@Suite("Workspace App REDCap Form Builder (Slice 5b)")
struct WorkspaceAppREDCapFormBuilderTests {
    private static func build(_ fields: [WorkspaceAppREDCapFieldMetadata]) -> WorkspaceAppManifest {
        WorkspaceAppREDCapFormBuilder.build(appID: "enroll", appName: "Enrollment", formName: "enrollment", fields: fields)
    }

    private static func formView(_ manifest: WorkspaceAppManifest) -> WorkspaceAppViewSpec? {
        manifest.views.first { $0.type == "form" }
    }

    // MARK: - Choice parsing

    @Test("a REDCap choice string parses into value/label form choices")
    func choiceStringParses() {
        let choices = WorkspaceAppREDCapChoiceParser.parse("1, Yes | 0, No | 2, No, with comma")
        #expect(choices.count == 3)
        #expect(choices[0] == WorkspaceAppFormChoice(value: "1", label: "Yes"))
        #expect(choices[2] == WorkspaceAppFormChoice(value: "2", label: "No, with comma"))  // label keeps inner comma
        #expect(WorkspaceAppREDCapChoiceParser.parse(nil).isEmpty)
    }

    // MARK: - Happy path

    @Test("safe REDCap metadata produces a valid, approval-gated form manifest")
    func safeMetadataProducesValidManifest() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "first_name", fieldLabel: "First name", fieldType: "text", required: true),
            WorkspaceAppREDCapFieldMetadata(fieldName: "age", fieldType: "text", validation: "integer"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "consent", fieldType: "radio", required: true, choices: "1, Yes | 0, No"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "visit_date", fieldType: "text", validation: "date_ymd")
        ])

        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(manifest.permissions.defaultMode == .approvalRequired)
        #expect(manifest.submitBlockedReasons == nil)

        // Draft table leads with REDCap's record key as a collected (not minted) text primary key.
        let table = try #require(manifest.storage?.tables.first)
        #expect(table.columns.first?.name == "record_id")
        #expect(table.columns.first?.primaryKey == true)

        // Governed submit through the declared write mode.
        let submit = try #require(manifest.actions.first { $0.type == "capability.write" })
        #expect(submit.operation == "submitCreate")
        #expect(submit.requirementRef == "recordWrite")
        #expect(submit.agentRequiresApproval)

        // A review view exists for the pre-submit screen.
        #expect(manifest.views.contains { $0.type == "review" })
    }

    @Test("REDCap field types and validations map to the right field + column types")
    func typeAndValidationMapping() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "notes_field", fieldType: "notes"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "count_field", fieldType: "text", validation: "integer"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "price_field", fieldType: "text", validation: "number"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "agree_field", fieldType: "yesno"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "meds_field", fieldType: "checkbox", choices: "1, A | 2, B")
        ])
        let form = try #require(Self.formView(manifest))
        func fieldType(_ name: String) -> String? { form.formFields.first { $0.name == name }?.fieldType }
        #expect(fieldType("notes_field") == "textarea")
        #expect(fieldType("count_field") == "number")
        #expect(fieldType("price_field") == "number")
        #expect(fieldType("agree_field") == "yesno")
        #expect(fieldType("meds_field") == "multichoice")

        let table = try #require(manifest.storage?.tables.first)
        func columnType(_ name: String) -> String? { table.columns.first { $0.name == name }?.type }
        #expect(columnType("count_field") == "integer")
        #expect(columnType("price_field") == "real")
        #expect(columnType("agree_field") == "bool")
    }

    @Test("required REDCap fields stay required on the form + draft column")
    func requiredMapping() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "mrn", fieldType: "text", required: true)
        ])
        let form = try #require(Self.formView(manifest))
        #expect(form.formFields.first { $0.name == "mrn" }?.required == true)
        let column = manifest.storage?.tables.first?.columns.first { $0.name == "mrn" }
        #expect(column?.required == true)
    }

    @Test("unsupported REDCap types are dropped from both fields and columns")
    func unsupportedTypesDropped() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "banner", fieldType: "descriptive"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "bmi", fieldType: "calc"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "scan", fieldType: "file"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "pain", fieldType: "slider"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "weird", fieldType: "signature")
        ])
        let form = try #require(Self.formView(manifest))
        #expect(form.formFields.isEmpty)
        // Only the record_id key column remains.
        #expect(manifest.storage?.tables.first?.columns.map(\.name) == ["record_id"])
    }

    // MARK: - Branching safety

    @Test("safe branching is preserved as visibleWhen; always-visible stays nil")
    func safeBranching() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "consent", fieldType: "radio", choices: "1, Yes | 0, No"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "dose", fieldType: "text", validation: "integer", branchingLogic: "[consent] = '1'"),
            WorkspaceAppREDCapFieldMetadata(fieldName: "always", fieldType: "text", branchingLogic: "   ")
        ])
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        let form = try #require(Self.formView(manifest))
        #expect(form.formFields.first { $0.name == "dose" }?.visibleWhen == "[consent] = '1'")
        #expect(form.formFields.first { $0.name == "always" }?.visibleWhen == nil)
        #expect(manifest.submitBlockedReasons == nil)
    }

    @Test("unsupported branching locks the field read-only and blocks submit")
    func unsupportedBranchingBlocksSubmit() throws {
        let manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(fieldName: "first_name", fieldType: "text", required: true),
            WorkspaceAppREDCapFieldMetadata(
                fieldName: "dose", fieldType: "text", validation: "integer",
                branchingLogic: "[a] = '1' and [b] = '2' or [c] = '3'"  // mixed and/or -> 5a unsupported
            )
        ])
        let form = try #require(Self.formView(manifest))
        let dose = try #require(form.formFields.first { $0.name == "dose" })
        #expect(dose.readOnly)
        #expect(dose.readOnlyReason?.contains("Unsupported branching") == true)
        #expect(dose.visibleWhen == nil)

        // Submit is blocked -> the form is forced read-only and STILL validates (it just can't submit).
        #expect((manifest.submitBlockedReasons ?? []).contains { $0.contains("dose") })
        #expect(manifest.permissions.defaultMode == .readOnly)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("the validator rejects a blocked form that tries to keep a live submit mode")
    func validatorRejectsBlockedFormWithLiveSubmit() {
        var manifest = Self.build([
            WorkspaceAppREDCapFieldMetadata(
                fieldName: "dose", fieldType: "text",
                branchingLogic: "datediff([dob], 'today', 'y') > 18"  // function -> unsupported -> blocked
            )
        ])
        #expect(manifest.submitBlockedReasons != nil)
        // Force a live-submit mode despite the block -> must be rejected.
        manifest.permissions.defaultMode = .approvalRequired
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path == "/submitBlockedReasons" })
    }
}
