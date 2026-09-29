import Testing
@testable import ASTRA
import AppKit
import SwiftUI

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

    @Test("By default the typed value renders in a plain text field")
    func defaultRendersAPlainTextField() {
        let controls = renderedControls(SecretEntryField("value", text: .constant("jane@example.com")))

        #expect(controls.plain == 1, "expected one plain text field, found \(controls)")
        #expect(controls.secure == 0, "the default must not mask what is being typed, found \(controls)")
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

    private struct RenderedControls: CustomStringConvertible {
        var plain = 0
        var secure = 0
        var description: String { "plain=\(plain) secure=\(secure)" }
    }

    /// Hosts `view`, lays it out, and counts the text controls SwiftUI built.
    private func renderedControls<V: View>(_ view: V) -> RenderedControls {
        let host = NSHostingView(rootView: view.frame(width: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

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
