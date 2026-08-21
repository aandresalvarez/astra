import Foundation
import ASTRACore

/// The outcome of testing one capability's connection from the New Workspace
/// wizard.
enum WorkspaceCapabilityValidationState: Equatable {
    case unchecked
    case checking
    case ready(String)
    case failed(String)
}

/// A read-only `SecretStore` over the credentials still sitting in the wizard's
/// draft, so a connector can be tested before anything is written to the
/// keychain.
struct WorkspaceSetupValidationSecretStore: SecretStore {
    var credentials: [String: String]

    func load(key: String, entityID _: String) -> String? {
        credentials[key] ?? credentials[key.uppercased()]
    }

    @discardableResult
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool {
        false
    }

    @discardableResult
    func delete(key _: String, entityID _: String) -> Bool {
        false
    }

    func deleteAll(entityID _: String) {}

    func exists(key: String, entityID _: String) -> Bool {
        load(key: key, entityID: "") != nil
    }
}

/// Records that the New Workspace wizard tested a capability, and how it went.
///
/// This path used to emit nothing at all. A user reported a GCP validation
/// failure from this screen and the log had no line for it: every `validation.*`
/// event in the file came from the capability *setup sheet*, which logs
/// `source=setup_sheet` and is reached a different way. The reported failure
/// left no trace, so the diagnosis had to be reconstructed from a screenshot.
///
/// The event names deliberately match the setup sheet's, so the two paths read
/// the same way in the log and are told apart by `source`.
enum WorkspaceCapabilityValidationTelemetry {
    static let source = "workspace_wizard"

    static func makeTraceID() -> String {
        AuditTrace.make("workspace-capability-validate")
    }

    static func started(packageID: String, traceID: String) {
        AppLogger.audit(.validationStarted, category: "Capabilities", fields: [
            "source": source,
            "trace_id": traceID,
            "package_id": packageID
        ])
    }

    /// The user changed the inputs while the test was in flight, so its answer
    /// was thrown away.
    ///
    /// Logged as `started` rather than as a pass or a failure: it is neither,
    /// and filing it under either would make the counts lie. It still gets a
    /// line, because "I pressed Test and nothing came back" is a real report
    /// and this is its explanation.
    static func superseded(packageID: String, traceID: String) {
        AppLogger.audit(.validationStarted, category: "Capabilities", fields: [
            "source": source,
            "trace_id": traceID,
            "package_id": packageID,
            "result": "superseded"
        ])
    }

    static func finished(
        packageID: String,
        traceID: String,
        state: WorkspaceCapabilityValidationState
    ) {
        var fields = [
            "source": source,
            "trace_id": traceID,
            "package_id": packageID
        ]
        let passed: Bool
        switch state {
        case .ready:
            passed = true
            fields["result"] = "passed"
        case .failed(let detail):
            passed = false
            fields["result"] = "failed"
            // The detail is what makes the line worth having. "GCP failed" was
            // already on screen; what it said is the part that was missing.
            // `audit` bounds field length itself.
            fields["detail"] = detail
        case .unchecked, .checking:
            // Unreachable today — validation only ever resolves to a terminal
            // state. Recorded rather than dropped so that a new case added to
            // the enum surfaces here instead of vanishing.
            passed = false
            fields["result"] = "indeterminate"
        }
        AppLogger.audit(
            passed ? .validationPassed : .validationFailed,
            category: "Capabilities",
            fields: fields,
            level: passed ? .info : .warning
        )
    }
}
