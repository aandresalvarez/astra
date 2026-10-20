import ASTRACore

/// Resolves a captured failure against the run's credential-file selection.
/// Resolution consumes structured facts; it never parses a diagnostic message.
enum RuntimeRepairContextResolver {
    static func resolve(_ context: RuntimeRepairContext, environment: [String: String]?) -> RuntimeRepairContext {
        let checked = context.repair.checking(in: environment)
        var repair = CLISessionExpiryClassifier.checkingCredentialFile(checked)
        guard repair.command != context.repair.command else { return context }
        // Environment credentials are process-local, never part of the durable
        // context. The resumed run supplies its projected environment again.
        repair.checkEnvironment = nil
        repair.checkWorkingDirectory = nil
        return RuntimeRepairContext(
            providerBinary: context.providerBinary, message: repair.detail,
            repair: repair, offersAction: false
        )
    }
}
