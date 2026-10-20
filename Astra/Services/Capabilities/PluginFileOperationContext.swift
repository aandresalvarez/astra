import Foundation

/// One operation's identity and optional prepared metadata participant. This
/// is call-scoped coordination; the receipt and journals own durable state.
struct PluginFileOperationContext {
    let id: UUID
    let metadataDigest: String
    let metadata: PluginFileOperationRecovery.MetadataHandler
}
