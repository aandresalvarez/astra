import Foundation
import Testing
@testable import ASTRA

@Suite("Google Workspace OAuth Setup Presentation")
struct GoogleWorkspaceOAuthSetupPresentationTests {
    @Test("managed client hides custom OAuth fields")
    func managedClientHidesCustomOAuthFields() {
        let presentation = GoogleWorkspaceOAuthSetupPresentation.make(
            settings: GoogleOAuthConfigurationSettings(
                clientID: "managed-client.apps.googleusercontent.com",
                redirectURI: GoogleOAuthConfigurationSettings.defaultRedirectURI,
                source: .managed
            )
        )

        #expect(presentation.mode == .managed)
        #expect(!presentation.showsCustomFields)
        #expect(presentation.primaryTitle == "ASTRA managed OAuth")
        #expect(presentation.primaryStatus == "Ready")
    }

    @Test("missing managed client shows guided custom OAuth setup")
    func missingManagedClientShowsGuidedCustomOAuthSetup() {
        let presentation = GoogleWorkspaceOAuthSetupPresentation.make(
            settings: GoogleOAuthConfigurationSettings(
                clientID: "",
                redirectURI: GoogleOAuthConfigurationSettings.defaultRedirectURI,
                source: .missing
            )
        )

        #expect(presentation.mode == .customRequired)
        #expect(presentation.showsCustomFields)
        #expect(presentation.primaryTitle == "Custom OAuth client")
        #expect(presentation.primaryStatus == "Setup required")
        #expect(presentation.actions.contains(.copyRedirectURI))
        #expect(presentation.actions.contains(.copyRequiredScopes))
        #expect(presentation.actions.contains(.openGoogleCloudConsole))
    }

    @Test("missing custom setup can switch back to managed OAuth when available")
    func missingCustomSetupCanSwitchBackToManagedOAuthWhenAvailable() {
        let presentation = GoogleWorkspaceOAuthSetupPresentation.make(
            settings: GoogleOAuthConfigurationSettings(
                clientID: "",
                redirectURI: GoogleOAuthConfigurationSettings.defaultRedirectURI,
                source: .missing
            ),
            managedClientAvailable: true
        )

        #expect(presentation.mode == .customRequired)
        #expect(presentation.actions.contains(.useManagedOAuth))
        #expect(presentation.actions.contains(.copyRedirectURI))
        #expect(presentation.actions.contains(.copyRequiredScopes))
        #expect(presentation.actions.contains(.openGoogleCloudConsole))
    }
}
