import ASTRACore
import Foundation

extension RunLedger {
    /// Pure admission validation used before capability preparation. This checks
    /// idempotency-key identity, execution/operation uniqueness, effect
    /// conflicts, authority, and immutable manifest invariants without writing.
    public func preflightExecutionAdmission(
        manifest: ExecutionLaunchManifest,
        primaryOperationID: RunBrokerOperationID,
        admittedAt: Date,
        idempotencyKey: UUID
    ) throws -> RunLedgerAppendResult {
        try preflightAppend(.init(
            eventID: .init(rawValue: idempotencyKey),
            occurredAt: admittedAt,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: primaryOperationID
            )
        ))
    }

    /// Atomically records a launch manifest and its primary effect claim. New
    /// provider launches must use this boundary so a crash cannot publish an
    /// unclaimed execution or an operation without its execution.
    @discardableResult
    public func admitExecution(
        manifest: ExecutionLaunchManifest,
        primaryOperationID: RunBrokerOperationID,
        admittedAt: Date,
        idempotencyKey: UUID
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: .init(rawValue: idempotencyKey),
            occurredAt: admittedAt,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: primaryOperationID
            )
        ))
    }
}
