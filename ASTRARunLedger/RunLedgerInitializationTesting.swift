import Darwin

/// Process-level crash seam used only by the standalone initialization
/// harness. SPI keeps fault injection out of the normal RunLedger API.
@_spi(RunLedgerTesting)
public enum RunLedgerInitializationCrashPoint: String, Sendable {
    case afterInitializationMarkerCreated = "after-initialization-marker-created"
    case afterMainFileCreated = "after-main-file-created"
    case beforeSchemaCommit = "before-schema-commit"
    case afterSchemaCommitBeforeMarkerRemoval = "after-schema-commit-before-marker-removal"
}

enum RunLedgerInitializationCrash {
    static func trigger(
        _ point: RunLedgerInitializationCrashPoint,
        requested: RunLedgerInitializationCrashPoint?
    ) -> Never? {
        guard requested == point else { return nil }
        Darwin._exit(86)
    }
}
