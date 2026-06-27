import Foundation

public enum MCPRuntimeBindingDestination: String, Codable, Equatable, Sendable, CaseIterable {
    case environment
    case httpHeader
}

public enum MCPRuntimeTemplateReferenceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case secretRef
    case configRef
    case authProfileRef
}

public struct MCPRuntimeTemplateReference: Codable, Equatable, Hashable, Sendable {
    public var kind: MCPRuntimeTemplateReferenceKind
    public var id: String

    public init(kind: MCPRuntimeTemplateReferenceKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func secret(_ id: String) -> MCPRuntimeTemplateReference {
        MCPRuntimeTemplateReference(kind: .secretRef, id: id)
    }

    public static func config(_ id: String) -> MCPRuntimeTemplateReference {
        MCPRuntimeTemplateReference(kind: .configRef, id: id)
    }

    public static func authProfile(_ id: String) -> MCPRuntimeTemplateReference {
        MCPRuntimeTemplateReference(kind: .authProfileRef, id: id)
    }
}

public enum MCPRuntimeTemplateSegmentKind: String, Codable, Equatable, Sendable, CaseIterable {
    case literal
    case reference
}

public struct MCPRuntimeTemplateSegment: Codable, Equatable, Sendable {
    public var kind: MCPRuntimeTemplateSegmentKind
    public var literal: String?
    public var reference: MCPRuntimeTemplateReference?

    public init(
        kind: MCPRuntimeTemplateSegmentKind,
        literal: String? = nil,
        reference: MCPRuntimeTemplateReference? = nil
    ) {
        self.kind = kind
        self.literal = literal
        self.reference = reference
    }

    public static func literal(_ value: String) -> MCPRuntimeTemplateSegment {
        MCPRuntimeTemplateSegment(kind: .literal, literal: value)
    }

    public static func reference(_ reference: MCPRuntimeTemplateReference) -> MCPRuntimeTemplateSegment {
        MCPRuntimeTemplateSegment(kind: .reference, reference: reference)
    }
}

public enum MCPRuntimeBindingLogRedaction: String, Codable, Equatable, Sendable, CaseIterable {
    case always
    case whenReferencesSensitive
}

public enum MCPRuntimeBindingInvariantViolation: Equatable, Sendable {
    case destinationNameRequired
    case idRequired
    case literalSegmentMustNotCarryReference
    case literalValueMustNotContainRawSecret
    case literalValueRequired
    case referenceSegmentMustNotCarryLiteral
    case referenceIDRequired
    case referenceSegmentRequired
    case templateRequired
    case undeclaredAuthProfileRef(String)
    case undeclaredConfigRef(String)
    case undeclaredSecretRef(String)
}

public struct MCPRuntimeBindingTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var destination: MCPRuntimeBindingDestination
    public var name: String
    public var template: [MCPRuntimeTemplateSegment]
    public var logRedaction: MCPRuntimeBindingLogRedaction

    public init(
        id: String,
        destination: MCPRuntimeBindingDestination,
        name: String,
        template: [MCPRuntimeTemplateSegment],
        logRedaction: MCPRuntimeBindingLogRedaction = .whenReferencesSensitive
    ) {
        self.id = id
        self.destination = destination
        self.name = name
        self.template = template
        self.logRedaction = logRedaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        destination = try container.decode(MCPRuntimeBindingDestination.self, forKey: .destination)
        name = try container.decode(String.self, forKey: .name)
        template = try container.decodeIfPresent([MCPRuntimeTemplateSegment].self, forKey: .template) ?? []
        logRedaction = try container.decodeIfPresent(
            MCPRuntimeBindingLogRedaction.self,
            forKey: .logRedaction
        ) ?? .whenReferencesSensitive
    }

    public var referencedSecretRefs: [String] {
        references(ofKind: .secretRef)
    }

    public var referencedConfigRefs: [String] {
        references(ofKind: .configRef)
    }

    public var referencedAuthProfileRefs: [String] {
        references(ofKind: .authProfileRef)
    }

    public func invariantViolations(
        declaredSecretRefs: Set<String>,
        declaredConfigRefs: Set<String>,
        declaredAuthProfileRefs: Set<String>
    ) -> [MCPRuntimeBindingInvariantViolation] {
        var violations: [MCPRuntimeBindingInvariantViolation] = []
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.idRequired)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.destinationNameRequired)
        }
        if template.isEmpty {
            violations.append(.templateRequired)
        }
        for segment in template {
            switch segment.kind {
            case .literal:
                if segment.reference != nil {
                    violations.append(.literalSegmentMustNotCarryReference)
                }
                if let literal = segment.literal {
                    if Self.literalLooksLikeRawSecretValue(literal) {
                        violations.append(.literalValueMustNotContainRawSecret)
                    }
                } else {
                    violations.append(.literalValueRequired)
                }
            case .reference:
                if segment.literal != nil {
                    violations.append(.referenceSegmentMustNotCarryLiteral)
                }
                guard let reference = segment.reference else {
                    violations.append(.referenceSegmentRequired)
                    continue
                }
                let referenceID = reference.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if referenceID.isEmpty {
                    violations.append(.referenceIDRequired)
                    continue
                }
                switch reference.kind {
                case .secretRef:
                    if !declaredSecretRefs.contains(referenceID) {
                        violations.append(.undeclaredSecretRef(referenceID))
                    }
                case .configRef:
                    if !declaredConfigRefs.contains(referenceID) {
                        violations.append(.undeclaredConfigRef(referenceID))
                    }
                case .authProfileRef:
                    if !declaredAuthProfileRefs.contains(referenceID) {
                        violations.append(.undeclaredAuthProfileRef(referenceID))
                    }
                }
            }
        }
        return violations
    }

    private static let rawSecretValueRegexes: [NSRegularExpression] = [
        #"(?i)\bbearer\s+[a-z0-9._~+/=-]{12,}"#,
        #"(?i)\b(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|secret|password)\b\s*[:=]\s*['"]?[^\s'";,]{8,}"#,
        #"(?i)\bya29\.[a-z0-9._-]{6,}"#,
        #"(?i)\b1//[a-z0-9._-]{6,}"#,
        #"(?i)\bAIza[0-9a-z_-]{8,}"#
    ].map { pattern in
        try! NSRegularExpression(pattern: pattern)
    }

    public static func literalLooksLikeRawSecretValue(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return rawSecretValueRegexes.contains { regex in
            regex.firstMatch(in: value, range: range) != nil
        }
    }

    private func references(ofKind kind: MCPRuntimeTemplateReferenceKind) -> [String] {
        template.compactMap { segment in
            guard segment.kind == .reference,
                  segment.reference?.kind == kind else {
                return nil
            }
            return segment.reference?.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
