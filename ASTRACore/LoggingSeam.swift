import Foundation
import os
import ASTRALogging

// Added as part of Track A2.3 (finishing A2's Models cycle-break) so
// `Astra/Models/Connector.swift` can record audit events without depending
// on `AppLogger` (Astra/Services/Diagnostics/Logger.swift), which must stay
// app-side - it has real dependencies on `AppChannel`, `LoggingPreferences`,
// and `HostFileAccessBroker` for sandboxed log-file I/O (the reason Track A1
// only extracted AppLogger's pure vocabulary types into the `ASTRALogging`
// leaf target, not `AppLogger` itself).
//
// Follows the exact registration pattern in `RuntimeSeams.swift`: a public
// protocol + an `OSAllocatedUnfairLock`-backed static registry with
// `.register(_:)` and a fail-fast `.required` accessor, wired up from
// `RuntimeSeamRegistration.registerAll()`.
public enum ConnectorAuditLoggingSeam {
    private static let storage = OSAllocatedUnfairLock<(any ConnectorAuditLogging.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ logger: any ConnectorAuditLogging.Type) {
        storage.withLock { $0 = logger }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    ///
    /// Unlike `TaskExecutionDefaults.model` (Track A2.2), this is safe to
    /// gate behind a trap: `Connector.testConnection()` is only invoked from
    /// an explicit user/test action that exercises the connector-test flow,
    /// never as a passive default-parameter value construction path, so it
    /// does not have that seam's "touched by nearly every test" ordering
    /// hazard.
    public static var required: any ConnectorAuditLogging.Type {
        guard let logger = storage.withLock({ $0 }) else {
            preconditionFailure(
                "ConnectorAuditLoggingSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return logger
    }
}

/// Records a connector-test audit event, matching `AppLogger.audit`'s
/// signature exactly so `AppLogger`'s existing conformance needs no changes.
public protocol ConnectorAuditLogging {
    static func audit(
        _ event: AuditEvent,
        category: String,
        taskID: UUID?,
        fields: [String: String],
        level: LogLevel,
        fieldMaxLength: Int
    )
}

extension ConnectorAuditLogging {
    /// Convenience overload matching `AppLogger.audit`'s own defaults
    /// (`category: "Audit"`, `taskID: nil`, `fields: [:]`, `level: .info`,
    /// `fieldMaxLength: 120`) - protocol requirements can't declare default
    /// parameter values, so this lives in an extension instead.
    public static func audit(
        _ event: AuditEvent,
        category: String = "Audit",
        taskID: UUID? = nil,
        fields: [String: String] = [:],
        level: LogLevel = .info
    ) {
        audit(event, category: category, taskID: taskID, fields: fields, level: level, fieldMaxLength: 120)
    }
}
