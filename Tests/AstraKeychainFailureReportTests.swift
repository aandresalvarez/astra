import Foundation
import Security
import Testing
import ASTRAPersistence

/// The Obj-C keychain layer has always known *why* the dedicated keychain could
/// not be opened, and has always thrown that knowledge away into a log line.
/// These tests pin the parse and the one distinction the UI depends on: an item
/// that exists and was refused is a different problem, with a different remedy,
/// than an item that is not there at all.
@Suite("Keychain failure report")
struct AstraKeychainFailureReportTests {

    /// The exact shape emitted by `AstraSecureKeychain`'s
    /// `stage=%@ status=%d suppressed=%lu`.
    @Test("Parses the report the Obj-C layer emits")
    func parsesTheEmittedReport() throws {
        let report = try #require(
            AstraKeychainFailureReport(rawReport: "stage=bootstrap-password status=-25293 suppressed=12")
        )

        #expect(report.stage == "bootstrap-password")
        #expect(report.status == errSecAuthFailed)
        #expect(report.suppressedCount == 12)
    }

    /// A partial line still carries the two fields that matter. The suppressed
    /// counter is the one field the backoff path can leave off.
    @Test("A report without a suppressed count parses as zero")
    func missingSuppressedCountDefaultsToZero() throws {
        let report = try #require(
            AstraKeychainFailureReport(rawReport: "stage=bootstrap-password status=-25300")
        )

        #expect(report.suppressedCount == 0)
        #expect(report.diagnosis == .notConfigured)
    }

    /// A format change in the Obj-C layer has to degrade to "no diagnosis"
    /// rather than to a confidently wrong one — the UI falls back to the
    /// access-prompt wording, which is the safe default.
    @Test("Anything without a stage and a status is rejected")
    func malformedReportsAreRejected() {
        #expect(AstraKeychainFailureReport(rawReport: "") == nil)
        #expect(AstraKeychainFailureReport(rawReport: "status=-25293") == nil)
        #expect(AstraKeychainFailureReport(rawReport: "stage=unlock") == nil)
        #expect(AstraKeychainFailureReport(rawReport: "stage= status=-25293") == nil)
        #expect(AstraKeychainFailureReport(rawReport: "stage=unlock status=denied") == nil)
    }

    /// The whole point of the type. `-25293` ran for 17 days in production
    /// behind 13 silent credential-save failures while the UI said the same
    /// thing it says for `-25300`.
    @Test("Access denial and a missing item are separate diagnoses")
    func diagnosisSeparatesDenialFromAbsence() throws {
        func diagnosis(_ status: OSStatus, stage: String = "unlock") throws -> AstraKeychainFailureReport.Diagnosis {
            try #require(AstraKeychainFailureReport(rawReport: "stage=\(stage) status=\(status)")).diagnosis
        }

        #expect(try diagnosis(errSecAuthFailed) == .accessDenied)
        #expect(try diagnosis(errSecInteractionNotAllowed) == .accessDenied)
        #expect(try diagnosis(errSecItemNotFound, stage: "bootstrap-password") == .notConfigured)
        #expect(try diagnosis(errSecSuccess) == .unknown)
        #expect(try diagnosis(-34018) == .unknown)
    }

    /// `.notConfigured` drives the one message with no button — "the key that
    /// unlocks the store is gone, and saving again will not help" — so it has
    /// to mean exactly the thing it says. Only the `bootstrap-password` stage
    /// reports -25300 with that meaning; the Obj-C layer filters it out of
    /// `item-delete` and no other stage produces it today. If one ever does,
    /// the status alone must not be allowed to put that message on screen.
    @Test("A missing item outside the bootstrap stage is not the missing-key diagnosis")
    func missingItemIsStageGated() throws {
        for stage in ["open", "unlock", "create", "search-list-restore", "item-delete", "item-add"] {
            let report = try #require(
                AstraKeychainFailureReport(rawReport: "stage=\(stage) status=\(errSecItemNotFound)")
            )
            #expect(report.diagnosis == .unknown, "stage \(stage) must not read as a lost bootstrap key")
        }
    }
}
