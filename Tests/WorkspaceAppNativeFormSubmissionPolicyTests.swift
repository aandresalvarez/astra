import Testing
@testable import ASTRA

@Suite("Workspace App Native Form Submission Policy")
struct WorkspaceAppNativeFormSubmissionPolicyTests {
    @Test("ordinary native form submit does not mint external write approval")
    func ordinaryNativeFormSubmitDoesNotMintExternalWriteApproval() throws {
        var manifest = WorkspaceAppManifest(app: WorkspaceAppManifestMetadata(
            id: "enroll",
            name: "Enrollment",
            icon: "person.crop.circle",
            description: "Enrollment form",
        ))
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "entry",
                type: "form",
                title: "Entry",
                table: "enrollment",
                formFields: [
                    WorkspaceAppFormFieldSpec(name: "participant_id", label: "Participant ID", fieldType: "text")
                ]
            )
        ]
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "submit",
                type: "capability.write",
                requirementRef: "redcapWrite",
                operation: "submitCreate",
                table: "enrollment"
            )
        ]
        let view = try #require(manifest.views.first)
        let record: [String: WorkspaceAppStorageValue] = ["participant_id": .text("P-001")]

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: record
        ))

        #expect(submission.action.id == "submit")
        #expect(submission.input.table == "enrollment")
        #expect(submission.input.record == record)
        #expect(submission.input.confirmedApproval == false)
        #expect(submission.input.confirmedDestructive == false)
    }
}
