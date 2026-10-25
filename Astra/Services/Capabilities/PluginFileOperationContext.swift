import Foundation
import ASTRACore

/// One operation's identity and optional prepared metadata participant. This
/// is call-scoped coordination; the receipt and journals own durable state.
struct PluginFileOperationContext {
    let id: UUID
    let metadataDigest: String
    let metadata: PluginFileOperationRecovery.MetadataHandler
    /// Derived from the source journal's prepared after-image for an Add.
    /// Domain reconciliation must use this target, not the still-live before.
    let plannedSource: PluginInstalledCopy?

    init(id: UUID, metadataDigest: String, metadata: PluginFileOperationRecovery.MetadataHandler,
        plannedSource: PluginInstalledCopy? = nil) {
        self.id = id; self.metadataDigest = metadataDigest; self.metadata = metadata
        self.plannedSource = plannedSource
    }

}
