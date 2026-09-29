import SwiftUI

/// How a credential is shown while someone is typing it.
///
/// Entry is visible unless the person hides it. A masked field gives no way to
/// see a mistyped value, and the values that go wrong are the ones a person can
/// check by eye: Jira keeps `JIRA_EMAIL` beside its API token as a Keychain
/// "secret" although it is an address, and a typo in it surfaced only when the
/// save was refused or the connection test failed. This is about what is being
/// typed right now; stored values stay masked behind each section's own eye.
enum SecretEntryPresentation {
    static let startsRevealed = true

    static func toggleSystemImage(isRevealed: Bool) -> String {
        isRevealed ? "eye.slash" : "eye"
    }

    static func toggleHelp(isRevealed: Bool) -> String {
        isRevealed ? "Hide value" : "Show value"
    }
}

/// One-line field for typing a credential: plain text by default, with an eye
/// to hide it (screen sharing, a shoulder behind you).
///
/// Every place that takes a credential from the keyboard uses this rather than
/// a bare `SecureField`, so the behaviour cannot drift between screens;
/// `SecretEntryFitnessTests` fails the build if one reappears.
struct SecretEntryField: View {
    private let prompt: String
    @Binding private var text: String
    @State private var isRevealed: Bool
    @FocusState private var isFocused: Bool

    init(
        _ prompt: String,
        text: Binding<String>,
        startsRevealed: Bool = SecretEntryPresentation.startsRevealed
    ) {
        self.prompt = prompt
        self._text = text
        self._isRevealed = State(initialValue: startsRevealed)
    }

    var body: some View {
        HStack(spacing: 6) {
            field
                .textFieldStyle(.roundedBorder)
                // A visible value is otherwise open to spelling correction and
                // text replacement, which would silently rewrite a token or an
                // address; `SecureField` never allowed either.
                .autocorrectionDisabled()
                .focused($isFocused)

            Button {
                isRevealed.toggle()
                // Swapping the field drops keyboard focus along with the old
                // one; keep the caret so the person can carry on typing.
                isFocused = true
            } label: {
                Image(systemName: SecretEntryPresentation.toggleSystemImage(isRevealed: isRevealed))
                    .font(Stanford.ui(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SecretEntryPresentation.toggleHelp(isRevealed: isRevealed))
            .accessibilityLabel(SecretEntryPresentation.toggleHelp(isRevealed: isRevealed))
        }
    }

    @ViewBuilder
    private var field: some View {
        if isRevealed {
            TextField(prompt, text: $text)
        } else {
            SecureField(prompt, text: $text)
        }
    }
}
