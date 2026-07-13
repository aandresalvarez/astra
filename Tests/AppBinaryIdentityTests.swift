import ASTRACore
import Testing

@testable import ASTRA

@Suite("App Binary Identity")
struct AppBinaryIdentityTests {
  @Test("packaged channel mismatch fails closed while unbundled tests stay neutral")
  func linkedChannelMustMatchEffectiveStorageChannel() {
    #expect(
      LinkedAppChannelIdentity.matches(
        effectiveChannel: .development,
        linkedChannel: .development
      )
    )
    #expect(
      !LinkedAppChannelIdentity.matches(
        effectiveChannel: .production,
        linkedChannel: .development
      )
    )
    #expect(
      LinkedAppChannelIdentity.matches(
        effectiveChannel: .production,
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
