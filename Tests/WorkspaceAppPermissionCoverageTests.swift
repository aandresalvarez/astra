import Foundation
import Testing
@testable import ASTRA

/// The validator reconciles the DECLARED permission surface against what the app's capability
/// actions/sources actually touch (using the contract registry's per-operation effects), emitting
/// warnings — not blockers — when a capability read/write isn't declared in the matching list.
@Suite("Workspace App Permission Coverage")
struct WorkspaceAppPermissionCoverageTests {
    private func manifest(
        requirements: [WorkspaceAppRequirement] = [],
        sources: [WorkspaceAppSource] = [],
        actions: [WorkspaceAppActionSpec] = [],
        reads: [String] = [],
        writes: [String] = [],
        externalWrites: [String] = [],
        mode: WorkspaceAppPermissionMode = .approvalRequired
    ) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "cap-app", name: "Capability App"),
            requirements: requirements,
            sources: sources,
            actions: actions,
            permissions: WorkspaceAppPermissions(reads: reads, writes: writes, externalWrites: externalWrites, defaultMode: mode)
        )
    }

    private let redcapWrite = WorkspaceAppRequirement(id: "redcapWrite", contract: "recordProject.write", operations: ["submitCreate"])
    private let redcapRead = WorkspaceAppRequirement(id: "redcapRead", contract: "recordProject.read", operations: ["readRecords"])

    private func submitAction(operation: String = "submitCreate") -> WorkspaceAppActionSpec {
        WorkspaceAppActionSpec(id: "submit", type: "capability.write", label: "Submit Record", requirementRef: "redcapWrite", operation: operation)
    }

    private func readSource() -> WorkspaceAppSource {
        WorkspaceAppSource(id: "records", requirementRef: "redcapRead", operation: "readRecords", projectRef: "study")
    }

    // MARK: - External writes

    @Test("an external-write action declared in permissions.externalWrites raises no coverage warning")
    func externalWriteDeclared() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapWrite], actions: [submitAction()], externalWrites: ["recordProject.write"])
        )
        #expect(report.isValid)
        #expect(!report.warnings.contains { $0.path == "/actions/0/requirementRef" })
    }

    @Test("an external-write action missing from permissions.externalWrites warns (not blocks)")
    func externalWriteUndeclared() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapWrite], actions: [submitAction()])
        )
        #expect(report.isValid)  // advisory only — runtime gates by permissionMode + effect
        #expect(report.warnings.contains {
            $0.path == "/actions/0/requirementRef" && $0.message.contains("permissions.externalWrites")
        })
    }

    @Test("a non-external capability.write (read-effect op) is checked against permissions.writes")
    func nonExternalWriteUsesWritesList() {
        // validateWrite is a .read-effect op on recordProject.write, so it routes to the writes list.
        let undeclared = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapWrite], actions: [submitAction(operation: "validateWrite")])
        )
        #expect(undeclared.warnings.contains {
            $0.path == "/actions/0/requirementRef" && $0.message.contains("permissions.writes")
        })
        let declared = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapWrite], actions: [submitAction(operation: "validateWrite")], writes: ["recordProject.write"])
        )
        #expect(!declared.warnings.contains { $0.path == "/actions/0/requirementRef" })
    }

    // MARK: - Read sources

    @Test("a capability-bound source declared in permissions.reads raises no coverage warning")
    func readSourceDeclared() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapRead], sources: [readSource()], reads: ["recordProject.read"], mode: .readOnly)
        )
        #expect(report.isValid)
        #expect(!report.warnings.contains { $0.path == "/sources/0/requirementRef" })
    }

    @Test("a capability-bound source missing from permissions.reads warns (not blocks)")
    func readSourceUndeclared() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(requirements: [redcapRead], sources: [readSource()], mode: .readOnly)
        )
        #expect(report.isValid)
        #expect(report.warnings.contains {
            $0.path == "/sources/0/requirementRef" && $0.message.contains("permissions.reads")
        })
    }

    // MARK: - No false positives

    @Test("an app-storage source (no capability requirement) is never flagged")
    func appStorageSourceNotFlagged() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(sources: [WorkspaceAppSource(id: "local", mode: "read", sourceRef: "appStorage")], mode: .draftOnly)
        )
        #expect(!report.warnings.contains { $0.path.hasPrefix("/sources/") })
    }

    @Test("a fully-declared read + external-write manifest has no coverage warnings")
    func fullyDeclaredIsClean() {
        let report = WorkspaceAppManifestValidator.validate(
            manifest(
                requirements: [redcapRead, redcapWrite],
                sources: [readSource()],
                actions: [submitAction()],
                reads: ["recordProject.read"],
                externalWrites: ["recordProject.write"]
            )
        )
        #expect(!report.warnings.contains { $0.path.hasPrefix("/sources/") || $0.path.hasPrefix("/actions/") })
    }
}
