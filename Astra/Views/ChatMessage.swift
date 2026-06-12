import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    let timestamp = Date()
}
