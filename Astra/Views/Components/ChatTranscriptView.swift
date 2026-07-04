import SwiftUI

enum ChatTranscriptRole {
    case user
    case assistant
    case status
}

enum ChatTranscriptUserBubbleStyle {
    case workspace
    case task

    var fill: Color {
        switch self {
        case .workspace:
            Stanford.sky.opacity(0.055)
        case .task:
            Color.primary.opacity(0.028)
        }
    }

    var stroke: Color {
        switch self {
        case .workspace:
            Stanford.sky.opacity(0.11)
        case .task:
            Color.primary.opacity(0.07)
        }
    }
}

struct ChatTranscriptUserBubble: View {
    let text: Text
    let timestamp: Date?
    let style: ChatTranscriptUserBubbleStyle

    init(text: String, timestamp: Date? = nil, style: ChatTranscriptUserBubbleStyle) {
        self.text = Text(text)
        self.timestamp = timestamp
        self.style = style
    }

    init(attributedText: AttributedString, timestamp: Date? = nil, style: ChatTranscriptUserBubbleStyle) {
        self.text = Text(attributedText)
        self.timestamp = timestamp
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 4) {
                text
                    .font(Stanford.chatBody())
                    .lineSpacing(Stanford.chatBodyLineSpacing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(style.fill)
                    .foregroundStyle(Stanford.readingText)
                    .tint(Stanford.link)
                    .clipShape(bubbleShape)
                    .overlay(bubbleShape.stroke(style.stroke, lineWidth: 1))
                    .textSelection(.enabled)

                if let timestamp {
                    Text(timestamp, style: .time)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                }
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: 16,
            bottomTrailingRadius: 4,
            topTrailingRadius: 16
        )
    }
}

struct ChatTranscriptCompactBubble: View {
    let text: String
    let role: ChatTranscriptRole
    let foreground: Color
    let background: Color
    var maxWidth: CGFloat = 380
    var minOppositeSpacing: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            if role == .user { Spacer(minLength: minOppositeSpacing) }
            Text(text)
                .font(Stanford.ui(13))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if role != .user { Spacer(minLength: minOppositeSpacing) }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }
}
