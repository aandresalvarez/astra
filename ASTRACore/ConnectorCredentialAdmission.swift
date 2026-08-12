import Foundation

// Admission control for connector credential values, added after a live
// Atlassian API token was pasted into a REDCap connector's `REDCAP_API_TOKEN`
// slot. The projection layer behaved correctly and handed that value to
// REDCap, which is exactly the problem: nothing between the paste and the
// outbound HTTPS request ever asked whether the value *could* be a REDCap
// token. Invariant #3 of the encapsulation work — "a value that cannot be a
// valid credential for its service is not storable as one".
//
// Everything here is pure and string-only so `Astra/Models/Connector.swift`
// can call it directly, matching the `ConnectorSecurityPolicy`
// (`credentialTransportViolation`) precedent: ASTRACore may never reference
// the `Connector` `@Model` type. The one rule that needs the live model — "is
// this exact value already owned by a connector for a *different* service?" —
// takes its input as the plain `ConnectorCredentialReuseSite` values below,
// which `ASTRAModels` gathers (see
// `ConnectorSecurityPolicy.credentialReuseSites(for:excluding:in:)`).
//
// Design bias throughout: a false rejection blocks a user from saving a
// credential that is actually fine, which is worse than a missed detection —
// the rules below back each other up. So every rule fails *open* when it is
// unsure, and only fires on positive, high-confidence evidence.

// MARK: - Declared format

/// The shape a connector credential is required to have, declared by the
/// capability package that owns it (`PluginConnector.CredentialHint.format`)
/// or supplied by `ConnectorCredentialFormatRegistry` for built-in services.
public struct ConnectorCredentialFormat: Codable, Sendable, Equatable {
    /// Regular expression the whole value must match. Implicitly anchored.
    public var pattern: String
    /// Human description of the expectation, used verbatim in the rejection
    /// message shown to the user (e.g. "32 hexadecimal characters").
    public var expectation: String

    public init(pattern: String, expectation: String) {
        self.pattern = pattern
        self.expectation = expectation
    }

    /// Fails open: a pattern that does not compile admits everything. A
    /// malformed declaration in a third-party capability package must not
    /// lock the user out of saving a perfectly valid credential.
    public func admits(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return true }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}

// MARK: - Vendor fingerprints

/// A credential format distinctive enough to name its issuer from the value
/// alone. Used for the rule that actually catches the clipboard mistake:
/// an unmistakably-Atlassian token saved onto a REDCap connector.
public struct ConnectorCredentialVendor: Sendable, Equatable {
    /// Display name of the issuer, e.g. "Atlassian".
    public let name: String
    /// Case-sensitive prefixes that identify this issuer beyond doubt.
    public let prefixes: [String]
    /// Minimum total length, so short prefixes cannot false-positive.
    public let minimumLength: Int
    /// Normalized connector service types this issuer's credentials belong to.
    public let serviceTypes: Set<String>

    func matches(_ value: String) -> Bool {
        guard value.count >= minimumLength else { return false }
        return prefixes.contains { value.hasPrefix($0) }
    }
}

// MARK: - Reuse sites

/// A connector, other than the one being written to, whose stored credentials
/// already hold the exact value being saved. Gathered in `ASTRAModels`, which
/// can see the `Connector` model; kept as flat data so the decision itself
/// stays pure.
public struct ConnectorCredentialReuseSite: Sendable, Equatable {
    public let connectorID: UUID
    public let connectorName: String
    public let serviceType: String
    public let credentialKey: String

    public init(connectorID: UUID, connectorName: String, serviceType: String, credentialKey: String) {
        self.connectorID = connectorID
        self.connectorName = connectorName
        self.serviceType = serviceType
        self.credentialKey = credentialKey
    }
}

// MARK: - Verdict

public enum ConnectorCredentialAdmissionVerdict: Sendable, Equatable {
    case admitted
    /// Empty once surrounding whitespace is trimmed.
    case empty
    /// A template/placeholder string rather than a real secret.
    case placeholder
    /// The value carries another vendor's unmistakable fingerprint.
    case foreignVendor(vendor: String, belongsTo: String, observedShape: String)
    /// The value cannot be a credential of the declared shape for this service.
    case formatMismatch(expectation: String, observedShape: String)
    /// The exact value is already this workspace's credential for a different
    /// service — a secret belongs to exactly one connector (invariant #1).
    case reusedAcrossServices(ownerName: String, ownerServiceType: String, credentialKey: String)

    public var isAdmitted: Bool { self == .admitted }

    /// Stable, low-cardinality reason for audit logging. Carries no value
    /// material and no user-supplied strings.
    public var auditReason: String {
        switch self {
        case .admitted: return "admitted"
        case .empty: return "empty"
        case .placeholder: return "placeholder"
        case .foreignVendor: return "foreign_vendor"
        case .formatMismatch: return "format_mismatch"
        case .reusedAcrossServices: return "reused_across_services"
        }
    }

    /// Explains the rejection to the user. Never contains the value itself —
    /// only its length and, where the issuer is already public knowledge from
    /// the prefix, the issuer's name.
    public func message(forKey key: String) -> String? {
        switch self {
        case .admitted:
            return nil
        case .empty:
            return "\(key) cannot be empty."
        case .placeholder:
            return "\(key) still looks like a placeholder rather than a real credential."
        case .foreignVendor(let vendor, let belongsTo, let observedShape):
            return "That value is \(observedShape) — a \(vendor) credential, not a \(belongsTo) one. "
                + "Each connector holds only its own service's secret, so paste the \(belongsTo) value for \(key)."
        case .formatMismatch(let expectation, let observedShape):
            return "\(key) should be \(expectation). The value you pasted is \(observedShape)."
        case .reusedAcrossServices(let ownerName, let ownerServiceType, let credentialKey):
            return "That exact value is already stored as \(credentialKey) on the “\(ownerName)” "
                + "(\(ownerServiceType)) connector. One secret belongs to one service — "
                + "paste this connector's own credential for \(key) instead."
        }
    }
}

public struct ConnectorCredentialAdmissionDecision: Sendable, Equatable {
    public let verdict: ConnectorCredentialAdmissionVerdict
    /// The value as it should actually be persisted — surrounding whitespace
    /// removed, because a trailing newline from a copy/paste is the single
    /// most common way a valid token is stored broken.
    public let normalizedValue: String

    public var isAdmitted: Bool { verdict.isAdmitted }

    public init(verdict: ConnectorCredentialAdmissionVerdict, normalizedValue: String) {
        self.verdict = verdict
        self.normalizedValue = normalizedValue
    }
}

// MARK: - Policy

public enum ConnectorCredentialAdmission {

    /// Service types that intentionally point at arbitrary endpoints, so no
    /// vendor fingerprint can be called "foreign" for them. Without this
    /// escape hatch a user could not build a custom connector against, say,
    /// the Atlassian API.
    public static let vendorAgnosticServiceTypes: Set<String> = [
        "", "custom", "rest_api", "restapi", "http", "https", "generic", "other", "webhook", "api"
    ]

    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedServiceType(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The whole decision, in evaluation order. Rules are ordered by how
    /// actionable their message is, not by strictness: naming the actual
    /// issuer ("this is an Atlassian token") tells the user what went wrong
    /// far better than "expected 32 hex characters".
    public static func evaluate(
        key: String,
        value rawValue: String,
        serviceType: String,
        declaredFormat: ConnectorCredentialFormat? = nil,
        reuseSites: [ConnectorCredentialReuseSite] = []
    ) -> ConnectorCredentialAdmissionDecision {
        let value = normalized(rawValue)
        let normalizedService = normalizedServiceType(serviceType)
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        func decide(_ verdict: ConnectorCredentialAdmissionVerdict) -> ConnectorCredentialAdmissionDecision {
            ConnectorCredentialAdmissionDecision(verdict: verdict, normalizedValue: value)
        }

        guard !value.isEmpty else { return decide(.empty) }

        if isPlaceholder(value) { return decide(.placeholder) }

        let vendor = ConnectorCredentialFormatRegistry.vendor(of: value)

        if let vendor,
           !vendorAgnosticServiceTypes.contains(normalizedService),
           !vendor.serviceTypes.contains(normalizedService) {
            return decide(.foreignVendor(
                vendor: vendor.name,
                belongsTo: normalizedService,
                observedShape: shapeDescription(value, vendor: vendor)
            ))
        }

        let format = declaredFormat
            ?? ConnectorCredentialFormatRegistry.format(serviceType: normalizedService, key: normalizedKey)
        if let format, !format.admits(value) {
            return decide(.formatMismatch(
                expectation: format.expectation,
                observedShape: shapeDescription(value, vendor: vendor)
            ))
        }

        // Same-service reuse is legitimate and common: several connectors can
        // front one Jira site with one token, and ASTRA's own stable keychain
        // namespace is *designed* to share a secret between equivalent rows.
        // Only a cross-service collision is unambiguously a mistake.
        if let collision = reuseSites.first(where: {
            normalizedServiceType($0.serviceType) != normalizedService
        }) {
            return decide(.reusedAcrossServices(
                ownerName: collision.connectorName,
                ownerServiceType: normalizedServiceType(collision.serviceType),
                credentialKey: collision.credentialKey
            ))
        }

        return decide(.admitted)
    }

    // MARK: Shape description

    /// Describes a value without ever reproducing it. The vendor name is safe
    /// to state: it is derived from a public, non-secret prefix the user can
    /// already see in the field they just pasted into.
    public static func shapeDescription(_ value: String, vendor: ConnectorCredentialVendor?) -> String {
        let count = value.count
        if let vendor {
            return "\(count) characters long and starts like a \(vendor.name) credential"
        }
        if count > 0, value.allSatisfy({ $0.isHexDigit }) {
            return "\(count) hexadecimal characters"
        }
        return "\(count) characters"
    }

    // MARK: Placeholder detection

    private static let placeholderWords: Set<String> = [
        "changeme", "change-me", "your-token-here", "yourtokenhere", "your_token_here",
        "token", "secret", "password", "apikey", "api-key", "api_key", "todo", "tbd",
        "placeholder", "none", "null", "nil", "n/a", "na", "example", "test", "dummy", "fixme"
    ]

    /// Deliberately narrow. Every rule here matches something no real API
    /// credential is ever shaped like.
    static func isPlaceholder(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if placeholderWords.contains(lowered) { return true }
        // <your-token>, {{TOKEN}}, ${TOKEN}
        if value.count >= 3, value.hasPrefix("<"), value.hasSuffix(">") { return true }
        if value.hasPrefix("{{"), value.hasSuffix("}}") { return true }
        if value.hasPrefix("${"), value.hasSuffix("}") { return true }
        // xxxx, ****, ......
        if value.count >= 3, let first = value.first, value.allSatisfy({ $0 == first }) { return true }
        return false
    }
}

// MARK: - Registry

/// The built-in half of the format rules: what ASTRA knows about the services
/// it ships connectors for, independent of any capability package's
/// declaration. `PluginConnector.CredentialHint.format` layers third-party
/// declarations on top; both feed the same
/// `ConnectorCredentialAdmission.evaluate`.
public enum ConnectorCredentialFormatRegistry {

    // MARK: Vendors

    /// Only issuers whose prefix is genuinely unambiguous. Deliberately
    /// excludes short or generic markers (a bare `sk-`, `dapi`) — the cost of
    /// a false positive is a user who cannot save a valid credential.
    public static let vendors: [ConnectorCredentialVendor] = [
        ConnectorCredentialVendor(
            name: "Atlassian",
            prefixes: ["ATATT", "ATCTT"],
            minimumLength: 24,
            serviceTypes: ["jira", "jira_cloud", "confluence", "atlassian", "bitbucket",
                           "jira_service_management", "jsm"]
        ),
        ConnectorCredentialVendor(
            name: "GitHub",
            prefixes: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"],
            minimumLength: 20,
            serviceTypes: ["github", "gh", "github_enterprise"]
        ),
        ConnectorCredentialVendor(
            name: "Slack",
            prefixes: ["xoxb-", "xoxp-", "xoxa-", "xoxe-", "xoxs-", "xapp-"],
            minimumLength: 20,
            serviceTypes: ["slack"]
        ),
        ConnectorCredentialVendor(
            name: "Google",
            prefixes: ["ya29.", "AIza"],
            minimumLength: 20,
            serviceTypes: ["gcloud", "google_cloud", "googlecloud", "gcp", "google",
                           "google_drive", "googledrive", "bigquery", "bq", "gemini"]
        ),
        ConnectorCredentialVendor(
            name: "AWS",
            prefixes: ["AKIA", "ASIA"],
            minimumLength: 16,
            serviceTypes: ["aws", "s3", "bedrock"]
        ),
        ConnectorCredentialVendor(
            name: "Anthropic",
            prefixes: ["sk-ant-"],
            minimumLength: 24,
            serviceTypes: ["anthropic", "claude"]
        ),
        ConnectorCredentialVendor(
            name: "OpenAI",
            prefixes: ["sk-proj-"],
            minimumLength: 24,
            serviceTypes: ["openai"]
        ),
        ConnectorCredentialVendor(
            name: "Stripe",
            prefixes: ["sk_live_", "rk_live_", "sk_test_", "pk_live_"],
            minimumLength: 20,
            serviceTypes: ["stripe"]
        ),
        ConnectorCredentialVendor(
            name: "npm",
            prefixes: ["npm_"],
            minimumLength: 20,
            serviceTypes: ["npm", "npmjs"]
        ),
        ConnectorCredentialVendor(
            name: "Hugging Face",
            prefixes: ["hf_"],
            minimumLength: 20,
            serviceTypes: ["huggingface", "hf"]
        )
    ]

    /// Longest matching prefix wins, so `sk-ant-` is never shadowed by a
    /// shorter entry added later.
    public static func vendor(of value: String) -> ConnectorCredentialVendor? {
        var best: (vendor: ConnectorCredentialVendor, length: Int)?
        for vendor in vendors {
            guard vendor.matches(value) else { continue }
            let matchedLength = vendor.prefixes
                .filter { value.hasPrefix($0) }
                .map(\.count)
                .max() ?? 0
            if best == nil || matchedLength > best!.length {
                best = (vendor, matchedLength)
            }
        }
        return best?.vendor
    }

    // MARK: Formats

    /// A REDCap project API token is documented as exactly 32 hexadecimal
    /// characters. This is the rule that would have refused the pasted
    /// Atlassian token outright.
    public static let redcapAPIToken = ConnectorCredentialFormat(
        pattern: "[0-9A-Fa-f]{32}",
        expectation: "a 32-character hexadecimal REDCap project API token (REDCap → API → your token)"
    )

    /// Atlassian Cloud Basic auth pairs the API token with the account's
    /// email address, and silently 401s when given a username instead.
    public static let emailAddress = ConnectorCredentialFormat(
        pattern: "[^@\\s]+@[^@\\s]+\\.[^@\\s]+",
        expectation: "an email address"
    )

    /// Deliberately sparse. A format is registered only where the service
    /// documents an unambiguous shape; anything else is left to the vendor
    /// fingerprint and cross-service reuse rules, which cannot false-positive
    /// on an unfamiliar-but-valid credential.
    public static func format(serviceType: String, key: String) -> ConnectorCredentialFormat? {
        let service = ConnectorCredentialAdmission.normalizedServiceType(serviceType)
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch service {
        case "redcap":
            if normalizedKey == "TOKEN" || normalizedKey.hasSuffix("_TOKEN") {
                return redcapAPIToken
            }
        case "jira", "jira_cloud", "confluence", "atlassian", "jira_service_management", "jsm":
            if normalizedKey == "EMAIL" || normalizedKey.hasSuffix("_EMAIL") {
                return emailAddress
            }
        default:
            return nil
        }
        return nil
    }
}
