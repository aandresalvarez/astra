import ASTRACore

/// Host and workspace checks use the same vocabulary: an advisory timeout
/// must not imply either a verified login or repository-specific failure.
enum CapabilityPrerequisitePresentation {
    static func label(_ prerequisite: CLIPrerequisite, status: HealthStatus?) -> String {
        switch status {
        case .healthy: "Ready"
        case .unverified: "Not verified"
        case .missingBinary: "Needs \(prerequisite.binary)"
        case .unauthenticated: "Needs login"
        case .authorizationRequired: "Authorize"
        case .unresponsive: "Check CLI"
        case .notChecked: "Not checked"
        case .none: "Check"
        }
    }
}
