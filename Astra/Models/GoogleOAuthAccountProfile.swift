import Foundation
import SwiftData
import ASTRACore

public enum GoogleOAuthAccountAuthState: String, Codable, Equatable, CaseIterable {
    case active
    case needsReauth
    case revoked
}

@Model
public final class GoogleOAuthAccountProfile {
    public var id: UUID
    public var subject: String
    public var email: String
    public var displayName: String
    public var avatarURLString: String?
    public var hostedDomain: String?
    public var grantedScopes: [String]
    public var requestedScopes: [String]
    public var authStateRaw: String
    public var authStateReason: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAuthenticatedAt: Date?
    public var revokedAt: Date?

    public var authState: GoogleOAuthAccountAuthState {
        get { GoogleOAuthAccountAuthState(rawValue: authStateRaw) ?? .active }
        set { authStateRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        subject: String,
        email: String,
        displayName: String = "",
        avatarURLString: String? = nil,
        hostedDomain: String? = nil,
        grantedScopes: [String] = [],
        requestedScopes: [String] = [],
        authState: GoogleOAuthAccountAuthState = .active,
        authStateReason: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lastAuthenticatedAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarURLString = avatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostedDomain = hostedDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.grantedScopes = GoogleOAuthScopeNormalizer.normalized(grantedScopes)
        self.requestedScopes = GoogleOAuthScopeNormalizer.normalized(requestedScopes)
        self.authStateRaw = authState.rawValue
        self.authStateReason = authStateReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.revokedAt = revokedAt
    }

    public func tokenLeakInspectionStrings() -> [String] {
        [
            id.uuidString,
            subject,
            email,
            displayName,
            avatarURLString ?? "",
            hostedDomain ?? "",
            grantedScopes.joined(separator: " "),
            requestedScopes.joined(separator: " "),
            authStateRaw,
            authStateReason,
            String(createdAt.timeIntervalSince1970),
            String(updatedAt.timeIntervalSince1970),
            lastAuthenticatedAt.map { String($0.timeIntervalSince1970) } ?? "",
            revokedAt.map { String($0.timeIntervalSince1970) } ?? ""
        ]
    }
}
