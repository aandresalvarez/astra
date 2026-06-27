import Foundation

public extension MCPControlPlaneInvariantViolation {
    var shortDescription: String {
        switch self {
        case .authProfileProviderIDRequired(let id):
            return "auth profile \(Self.displayID(id)) is missing a provider ID"
        case .authProfileRefIDRequired:
            return "auth profile ref ID is required"
        case .configRefIDRequired:
            return "config ref ID is required"
        case .duplicateAuthProfileRef(let id):
            return "duplicate auth profile ref \(Self.displayID(id))"
        case .duplicateConfigRef(let id):
            return "duplicate config ref \(Self.displayID(id))"
        case .duplicateProviderCapability(let id):
            return "duplicate provider capability \(Self.displayID(id))"
        case .duplicateRuntimeBinding(let id):
            return "duplicate runtime binding \(Self.displayID(id))"
        case .duplicateSecretRef(let id):
            return "duplicate secret ref \(Self.displayID(id))"
        case .providerCapability(let id, let nested):
            return "provider capability \(Self.displayID(id)) is invalid: \(nested.shortDescription)"
        case .runtimeBinding(let id, let nested):
            return "runtime binding \(Self.displayID(id)) is invalid: \(nested.shortDescription)"
        case .secretRefIDRequired:
            return "secret ref ID is required"
        }
    }

    private static func displayID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<empty>" : trimmed
    }
}

private extension MCPProviderCapabilityInvariantViolation {
    var shortDescription: String {
        switch self {
        case .contractIDRequired:
            return "contract ID is required"
        case .idRequired:
            return "provider capability ID is required"
        case .undeclaredAuthProfileRef(let id):
            return "undeclared auth profile ref \(displayID(id))"
        case .undeclaredConfigRef(let id):
            return "undeclared config ref \(displayID(id))"
        case .undeclaredSecretRef(let id):
            return "undeclared secret ref \(displayID(id))"
        }
    }
}

private extension MCPRuntimeBindingInvariantViolation {
    var shortDescription: String {
        switch self {
        case .destinationNameRequired:
            return "destination name is required"
        case .idRequired:
            return "runtime binding ID is required"
        case .literalSegmentMustNotCarryReference:
            return "literal segment must not carry a reference"
        case .literalValueMustNotContainRawSecret:
            return "literal value must not contain a raw secret"
        case .literalValueRequired:
            return "literal value is required"
        case .referenceSegmentMustNotCarryLiteral:
            return "reference segment must not carry a literal"
        case .referenceIDRequired:
            return "reference ID is required"
        case .referenceSegmentRequired:
            return "reference segment is required"
        case .templateRequired:
            return "template is required"
        case .undeclaredAuthProfileRef(let id):
            return "undeclared auth profile ref \(displayID(id))"
        case .undeclaredConfigRef(let id):
            return "undeclared config ref \(displayID(id))"
        case .undeclaredSecretRef(let id):
            return "undeclared secret ref \(displayID(id))"
        }
    }
}

private func displayID(_ id: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "<empty>" : trimmed
}
