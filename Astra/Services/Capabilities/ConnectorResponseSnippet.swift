import Foundation

enum ConnectorResponseSnippet {
    static func text(from data: Data, maxBytes: Int = 500) -> String {
        guard !data.isEmpty, maxBytes > 0 else { return "" }
        return String(decoding: data.prefix(maxBytes), as: UTF8.self)
    }
}
