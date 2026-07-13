import ASTRACore
import Testing

@testable import ASTRA

@Suite("App Binary Identity")
struct AppBinaryIdentityTests {
  @Test("packaged channel mismatch fails closed while unbundled tests stay neutral")
  func linkedChannelMustMatchBundle() {
    #expect(
      LinkedAppChannelIdentity.matches(
        bundleChannelRawValue: "dev",
        linkedChannel: .development
      )
    )
    #expect(
      !LinkedAppChannelIdentity.matches(
        bundleChannelRawValue: "prod",
        linkedChannel: .development
      )
    )
    #expect(
      LinkedAppChannelIdentity.matches(
        bundleChannelRawValue: "prod",
        linkedChannel: nil
      )
    )
  }

  @Test("plain SwiftPM test binaries do not advertise App Intents")
  func unbundledTestBinaryDisablesAppIntents() {
    #expect(!AstraAppShortcutRegistration.isEnabled)
    #expect(AstraAppShortcutRegistration.binaryMarker == "astra-app-intents:disabled")
  }
}
