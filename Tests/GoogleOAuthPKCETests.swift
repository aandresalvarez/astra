import Testing
@testable import ASTRA

@Suite("Google OAuth PKCE")
struct GoogleOAuthPKCETests {
    @Test("challenge is URL safe and deterministic for a verifier")
    func challengeIsURLSafe() throws {
        let verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        let challenge = try GoogleOAuthPKCE.challenge(for: verifier)

        #expect(challenge.range(of: "+") == nil)
        #expect(challenge.range(of: "/") == nil)
        #expect(challenge.range(of: "=") == nil)
        let secondChallenge = try GoogleOAuthPKCE.challenge(for: verifier)
        #expect(challenge == secondChallenge)
    }

    @Test("state validation rejects mismatches")
    func stateValidationRejectsMismatch() {
        #expect(GoogleOAuthPKCE.validate(returnedState: "abc", expectedState: "abc"))
        #expect(!GoogleOAuthPKCE.validate(returnedState: "abc", expectedState: "xyz"))
        #expect(!GoogleOAuthPKCE.validate(returnedState: "", expectedState: "xyz"))
    }

    @Test("generated verifier and state are nonempty URL safe values")
    func generatedValuesAreURLSafe() {
        let material = GoogleOAuthPKCE.generate()

        #expect(material.codeVerifier.count >= 43)
        #expect(material.state.count >= 24)
        #expect(material.codeVerifier.range(of: "+") == nil)
        #expect(material.codeVerifier.range(of: "/") == nil)
        #expect(material.state.range(of: "+") == nil)
        #expect(material.state.range(of: "/") == nil)
    }
}
