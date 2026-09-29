import Testing
@testable import ASTRA
import AppKit
import SwiftUI
import Observation

/// The behavioural half of the secret-entry rule; the source scan that stops a
/// bare `SecureField` reappearing is `SecretEntryFitnessTests`.
///
/// `TextField` and `SecureField` are different AppKit controls underneath
/// (`NSTextField` and its `NSSecureTextField` subclass), which is what lets a
/// hosted view answer "can the person see what they are typing?" without
/// reading pixels.
@MainActor
@Suite("Secret entry field")
struct SecretEntryFieldTests {
    @Test("Credential entry starts visible")
    func credentialEntryStartsVisible() {
        // The product decision: someone typing a Jira email or a token can see
        // it. Flipping this default brings back the mistyped-and-invisible
        // failure that SecretEntryField exists to remove.
        #expect(SecretEntryPresentation.startsRevealed)
    }

    @Test("The eye names the action it will take")
    func theEyeNamesTheActionItWillTake() {
        #expect(SecretEntryPresentation.toggleSystemImage(isRevealed: true) == "eye.slash")
        #expect(SecretEntryPresentation.toggleSystemImage(isRevealed: false) == "eye")
        #expect(SecretEntryPresentation.toggleHelp(isRevealed: true) == "Hide value")
        #expect(SecretEntryPresentation.toggleHelp(isRevealed: false) == "Show value")
    }

    @Test("Only identifiers read back in the clear once stored")
    func onlyIdentifiersReadBackInTheClear() {
        for key in ["JIRA_EMAIL", "EMAIL", "jira_email", " JIRA_EMAIL ", "SSH_USERNAME", "USERNAME"] {
            #expect(SecretEntryPresentation.isIdentifierKey(key), "\(key) is an identity and should be readable")
        }
        // A credential stays masked, including one whose name merely mentions an email.
        for key in ["JIRA_API_TOKEN", "JIRA_EMAIL_TOKEN", "EMAIL_PASSWORD", "USERNAME_SECRET",
                    "REDCAP_API_TOKEN", "SSH_PRIVATE_KEY", "EMAILS", "JIRA_PROJECTS", ""] {
            #expect(!SecretEntryPresentation.isIdentifierKey(key), "\(key) must stay masked")
        }
    }

    @Test("By default the typed value renders in a plain text field")
    func defaultRendersAPlainTextField() {
        let controls = renderedControls(SecretEntryField("value", text: .constant("")))

        #expect(controls.plain == 1, "expected one plain text field, found \(controls)")
        #expect(controls.secure == 0, "the default must not mask what is being typed, found \(controls)")
    }

    @Test("A value that was already stored starts hidden")
    func aStoredValueStartsHidden() {
        let controls = renderedControls(SecretEntryField("value", text: .constant("ATATT3xFfGF0stored")))

        #expect(controls.secure == 1, "a token copied from storage must not appear in the clear, found \(controls)")
        #expect(controls.plain == 0, "found \(controls)")
    }

    @Test("An identifier that was already stored may start visible")
    func aStoredIdentifierMayStartVisible() {
        let controls = renderedControls(
            SecretEntryField("value", text: .constant("jane@example.com"), hidesValuesNotTyped: false)
        )

        #expect(controls.plain == 1, "found \(controls)")
        #expect(controls.secure == 0, "found \(controls)")
    }

    @Test("A value that arrives while nobody is typing is hidden")
    func aValueThatArrivesWithoutTypingIsHidden() {
        // "Copy setup from another workspace" fills the field from the Keychain.
        let box = ArrivingValue()
        let host = host(ArrivingField(box: box))
        #expect(controls(in: host).plain == 1, "an empty field starts visible")

        box.value = "ATATT3xFfGF0copied"
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }

        let after = controls(in: host)
        #expect(after.secure == 1, "a copied token must be hidden once it arrives, found \(after)")
        #expect(after.plain == 0, "found \(after)")
    }

    @Test("Hidden, the same field renders as a secure field")
    func hiddenRendersASecureField() {
        let controls = renderedControls(
            SecretEntryField("value", text: .constant("jane@example.com"), startsRevealed: false)
        )

        #expect(controls.secure == 1, "expected one secure field, found \(controls)")
        #expect(controls.plain == 0, "a hidden field must not also show the value, found \(controls)")
    }

    // MARK: - Hosting

    @Observable
    final class ArrivingValue {
        var value = ""
    }

    struct ArrivingField: View {
        let box: ArrivingValue

        var body: some View {
            SecretEntryField("value", text: Binding(get: { box.value }, set: { box.value = $0 }))
        }
    }

    private struct RenderedControls: CustomStringConvertible {
        var plain = 0
        var secure = 0
        var description: String { "plain=\(plain) secure=\(secure)" }
    }

    private func renderedControls<V: View>(_ view: V) -> RenderedControls {
        controls(in: host(view))
    }

    /// Hosts `view` in a window and lays it out.
    private func host<V: View>(_ view: V) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        retainedWindows.append(window)
        return host
    }

    private var retainedWindows: [NSWindow] {
        get { Self.windows }
        nonmutating set { Self.windows = newValue }
    }
    private static var windows: [NSWindow] = []

    /// Counts the text controls SwiftUI built.
    private func controls(in host: NSView) -> RenderedControls {
        var controls = RenderedControls()
        func visit(_ node: NSView) {
            if node is NSSecureTextField {
                controls.secure += 1
            } else if node is NSTextField {
                controls.plain += 1
            }
            node.subviews.forEach(visit)
        }
        visit(host)
        return controls
    }
}
