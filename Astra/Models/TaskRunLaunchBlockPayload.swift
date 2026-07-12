import Foundation
import ASTRACore

/// Structured record of why a run was blocked before (or without) launching a
/// provider process. Persisted as a `TaskEvent` payload
/// (`TaskEventTypes.System.runtimeLaunchBlocked`) scoped to the specific run
/// via `TaskEvent.run`, alongside the existing free-text `"error"` event kept
/// for historical/generic display. Both block producers —
/// `AgentRuntimeWorker.shouldStartProvider`'s pre-launch `PolicyDiagnostic`
/// gate and `AgentRuntimeCapabilityBlockRecorder`'s runtime-compatibility gate
/// — emit this so downstream UI reads one typed source instead of parsing
/// prose back out of an event payload string.
public struct TaskRunLaunchBlockPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case policyDiagnostic
        case runtimeIncompatible
    }

    public var kind: Kind
    public var title: String
    public var message: String
    public var remediation: String?
    public var missingCapabilities: [String]
    /// Raw `AgentRuntimeID.rawValue` of a compatible fallback runtime, when
    /// one exists. Kept as a raw string (not the typed enum) since this
    /// crosses a persistence boundary — decoding stays possible even if the
    /// runtime ID it names is later removed.
    public var suggestedRuntimeID: String?

    public init(
        kind: Kind,
        title: String,
        message: String,
        remediation: String? = nil,
        missingCapabilities: [String] = [],
        suggestedRuntimeID: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.remediation = remediation
        self.missingCapabilities = missingCapabilities
        self.suggestedRuntimeID = suggestedRuntimeID
    }

    /// Decodes a payload previously written via
    /// `TaskEvent.structuredPayloadEvent(eventType: TaskEventTypes.System.runtimeLaunchBlocked, ...)`.
    /// Returns `nil` for a run that predates this event type, or wasn't
    /// blocked — callers treat that as "fall back to generic copy", not an error.
    public static func decode(from payload: String) -> TaskRunLaunchBlockPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskRunLaunchBlockPayload.self, from: data)
    }

    /// Builds the payload for `shouldStartProvider`'s pre-launch policy gate.
    /// Combines every blocked diagnostic's remediation, not just the first —
    /// a single-diagnostic block still reads as one clean sentence.
    public static func forPolicyDiagnostics(_ diagnostics: [PolicyDiagnostic]) -> TaskRunLaunchBlockPayload {
        let combinedRemediation = diagnostics.compactMap(\.remediation).joined(separator: " ")
        return TaskRunLaunchBlockPayload(
            kind: .policyDiagnostic,
            title: diagnostics.count == 1
                ? diagnostics[0].title
                : "Provider policy blocked this run before launch",
            message: diagnostics.map { "\($0.title): \($0.message)" }.joined(separator: " "),
            remediation: combinedRemediation.isEmpty ? nil : combinedRemediation,
            missingCapabilities: diagnostics.compactMap(\.affectedCapability)
        )
    }
}
