import ASTRACore

/// A channel identity compiled into the executable itself. Bundle metadata can
/// rename one binary, but it cannot give identical Mach-O bytes distinct UUIDs.
enum LinkedAppChannelIdentity {
  #if ASTRA_LINKED_CHANNEL_DEV
    static let channel: AppChannel? = .development
    static let marker = "astra-linked-channel:dev"
  #elseif ASTRA_LINKED_CHANNEL_BETA
    static let channel: AppChannel? = .beta
    static let marker = "astra-linked-channel:beta"
  #elseif ASTRA_LINKED_CHANNEL_PROD
    static let channel: AppChannel? = .production
    static let marker = "astra-linked-channel:prod"
  #else
    /// `swift test` and `swift run` do not go through the app bundler. They
    /// remain channel-neutral rather than pretending to be a packaged app.
    static let channel: AppChannel? = nil
    static let marker = "astra-linked-channel:unspecified"
  #endif

  static func matches(
    bundleChannelRawValue: String,
    linkedChannel: AppChannel? = channel
  ) -> Bool {
    guard let linkedChannel else { return true }
    return linkedChannel.rawValue == bundleChannelRawValue.lowercased()
  }
}
