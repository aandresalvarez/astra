import Foundation
import ASTRACore

extension Connector {
    /// Durable interpretation metadata, not another credential owner. The
    /// actual generation remains credentialNamespaceID on the account.
    public var outlookCredentialFormat: String? {
        get { OutlookCredentialIdentity.format(keys: configKeys, values: configValues) }
        set {
            let kept = configKeys.indices.filter { configKeys[$0] != OutlookCredentialIdentity.formatKey }
            let values = kept.map { $0 < configValues.count ? configValues[$0] : "" }
            configKeys = kept.map { configKeys[$0] }
            configValues = values
            if let newValue, !newValue.isEmpty {
                configKeys.append(OutlookCredentialIdentity.formatKey)
                configValues.append(newValue)
            }
        }
    }
}
