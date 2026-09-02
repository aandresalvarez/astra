import Foundation
import ASTRACore
import ASTRAModels

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

    /// - Parameter credentials: the draft values the test was run with, so the
    ///   detail can be scrubbed of them before it is written.
    static func finished(
        packageID: String,
        traceID: String,
        state: WorkspaceCapabilityValidationState,
        credentials: [String: String] = [:]
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
            fields["detail"] = redacted(detail, credentials: credentials)
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

    /// Scrubs the wizard's draft credentials out of a provider's error text.
    ///
    /// A connector test sends the token the user just typed, and some endpoints
    /// — a campus proxy, a misconfigured gateway, REDCap itself for certain
    /// argument errors — quote the submitted parameters back in their JSON
    /// error. `Connector.redcapAPIError` returns that body as the failure
    /// detail, so persisting it verbatim wrote a second cleartext copy of the
    /// token into the audit log. Nothing else covers it: these values are still
    /// draft, not yet in the Keychain and not attached to any task, so
    /// `RunSecretRedactionScope` has never heard of them.
    ///
    /// Redacted rather than dropped. The detail is the reason this event
    /// records anything at all — a user reporting "it failed" with no line in
    /// the log is what it was added for — and a scrubbed message still says
    /// which host refused and why.
    static func redacted(_ detail: String, credentials: [String: String]) -> String {
        RunSecretRedaction.redact(
            detail,
            secrets: credentials.values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= RunSecretRedaction.minimumSecretLength }
        )
    }
}

/// The connector half of the New Workspace wizard's Test Connection button.
///
/// Extracted from `ContentView` so the draft credentials a test submits and the
/// draft credentials the audit line has to scrub are one list rather than two.
/// A second copy would go stale exactly when a new connector is added, and the
/// symptom would be a token in the log rather than a compile error.
enum WorkspaceCapabilityConnectorValidation {
    /// The draft credentials a package's connection test sends.
    ///
    /// Empty for packages whose test spends a subprocess rather than a
    /// credential (`github`, `gcloud`): nothing the user typed goes on the wire,
    /// so there is nothing for the audit line to scrub.
    static func draftCredentials(
        packageID: String,
        configuration: OnboardingCapabilityConfiguration
    ) -> [String: String] {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            [
                "JIRA_EMAIL": configuration.jiraEmail,
                "JIRA_API_TOKEN": configuration.jiraAPIToken
            ]
        case OnboardingCapabilitySetup.redcapPackageID:
            ["REDCAP_API_TOKEN": configuration.redcapAPIToken]
        default:
            [:]
        }
    }

    @MainActor
    static func validate(
        packageID: String,
        connector: Connector,
        credentials: [String: String],
        source: String
    ) async -> WorkspaceCapabilityValidationState {
        let result = await connector.testConnection(
            store: WorkspaceSetupValidationSecretStore(credentials: credentials),
            source: source,
            packageID: packageID,
            traceID: AuditTrace.make("workspace-capability-validate")
        )
        return result.0 ? .ready(result.1) : .failed(result.1)
    }

    @MainActor
    static func jiraConnector(configuration: OnboardingCapabilityConfiguration) -> Connector {
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            icon: "list.bullet.clipboard",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: trimmed(configuration.jiraBaseURL),
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.credentialValues = ["", ""]
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = [trimmed(configuration.jiraProjects)]
        return connector
    }

    @MainActor
    static func redcapConnector(configuration: OnboardingCapabilityConfiguration) -> Connector {
        let connector = Connector(
            name: "REDCap",
            serviceType: "redcap",
            icon: "tablecells",
            connectorDescription: "Stanford REDCap API",
            baseURL: trimmed(configuration.redcapAPIURL),
            authMethod: "api_key"
        )
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        connector.credentialValues = [""]
        connector.testHTTPMethod = "POST"
        return connector
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
