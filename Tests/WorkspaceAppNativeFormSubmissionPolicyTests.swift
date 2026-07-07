import Testing
@testable import ASTRA

@Suite("Workspace App Native Form Submission Policy")
struct WorkspaceAppNativeFormSubmissionPolicyTests {
    @Test("ordinary native form submit does not mint external write approval")
    func ordinaryNativeFormSubmitDoesNotMintExternalWriteApproval() throws {
        let manifest = Self.manifest(actions: [
            Self.action(id: "submit", operation: "submitCreate")
        ])
        let view = try #require(manifest.views.first)

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record
        ))

        #expect(submission.action.id == "submit")
        #expect(submission.input.table == "enrollment")
        #expect(submission.input.record == Self.record)
        #expect(submission.input.confirmedApproval == false)
        #expect(submission.input.confirmedDestructive == false)
        #expect(submission.requiresExplicitApproval == false)
    }

    @Test("native form submit chooses the submitCreate action when multiple writes target the table")
    func nativeFormSubmitChoosesSubmitCreateAction() throws {
        let manifest = Self.manifest(actions: [
            Self.action(id: "prepare", operation: "prepareCreate"),
            Self.action(id: "submit", operation: "submitCreate"),
            Self.action(id: "validate", operation: "validateWrite")
        ])
        let view = try #require(manifest.views.first)

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record
        ))

        #expect(submission.action.id == "submit")
        #expect(submission.action.operation == "submitCreate")
        #expect(submission.requiresExplicitApproval == false)
    }

    @Test("native REDCap submit carries explicit approval through the submit action")
    func nativeREDCapSubmitCarriesExplicitApproval() throws {
        let manifest = Self.manifest(actions: [
            Self.action(
                id: "submit",
                operation: "submitCreate",
                approvalPrompt: "Submit this record to REDCap?",
                approvalDecisions: ["Submit", "Cancel"],
                agentRequiresApproval: true
            )
        ])
        let view = try #require(manifest.views.first)

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record
        ))

        #expect(submission.action.id == "submit")
        #expect(submission.requiresExplicitApproval == true)
        #expect(submission.approvalPresentation?.prompt == "Submit this record to REDCap?")
        #expect(submission.approvalPresentation?.confirmLabel == "Submit")
        #expect(submission.input.confirmedApproval == false)
        #expect(submission.input.confirmedDestructive == false)
    }

    @Test("approvalRequired native writes show approval UI even without action prompt decorations")
    func approvalRequiredNativeWritesUseFallbackApprovalUI() throws {
        var manifest = Self.manifest(
            actions: [Self.action(id: "submit", operation: "submitCreate")]
        )
        manifest.permissions.defaultMode = .approvalRequired
        let view = try #require(manifest.views.first)

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record
        ))

        #expect(submission.requiresExplicitApproval == true)
        #expect(submission.approvalPresentation?.prompt == "Review and approve this submission before it writes to the external system.")
        #expect(submission.approvalPresentation?.confirmLabel == "Approve")
        #expect(submission.input.confirmedApproval == false)
    }

    @Test("negative-only approval decisions do not become the confirm action")
    func negativeOnlyApprovalDecisionsUseUnambiguousApproveLabel() throws {
        var manifest = Self.manifest(actions: [
            Self.action(
                id: "submit",
                operation: "submitCreate",
                approvalPrompt: "Submit this record?",
                approvalDecisions: ["Reject", "Cancel"]
            )
        ])
        manifest.permissions.defaultMode = .approvalRequired
        let view = try #require(manifest.views.first)

        let submission = try #require(WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record
        ))

        #expect(submission.requiresExplicitApproval == true)
        #expect(submission.approvalPresentation?.confirmLabel == "Approve")
    }

    @Test("explicit approval resume fails closed when action id is no longer current")
    func explicitApprovalResumeRequiresCurrentActionID() throws {
        let manifest = Self.manifest(actions: [
            Self.action(id: "submit", operation: "submitCreate")
        ])
        let view = try #require(manifest.views.first)

        let submission = WorkspaceAppNativeFormSubmissionPolicy.submission(
            for: view,
            manifest: manifest,
            values: Self.record,
            actionID: "removed-submit"
        )

        #expect(submission?.action.id == nil)
    }

    private static let record: [String: WorkspaceAppStorageValue] = ["participant_id": .text("P-001")]

    private static func manifest(actions: [WorkspaceAppActionSpec]) -> WorkspaceAppManifest {
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
        manifest.actions = actions
        return manifest
    }

    private static func action(
        id: String,
        operation: String,
        table: String? = "enrollment",
        approvalPrompt: String? = nil,
        approvalDecisions: [String]? = nil,
        agentRequiresApproval: Bool = false
    ) -> WorkspaceAppActionSpec {
        WorkspaceAppActionSpec(
            id: id,
            type: "capability.write",
            requirementRef: "redcapWrite",
            operation: operation,
            table: table,
            approvalPrompt: approvalPrompt,
            approvalDecisions: approvalDecisions ?? [],
            agentRequiresApproval: agentRequiresApproval
        )
    }
}
