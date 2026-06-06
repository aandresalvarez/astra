import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ASTRA

/// Lock in the dark-mode story. Without these tests it's trivially easy
/// to quietly regress a brand color back to a fixed-hex value that
/// disappears on a dark background. Each test resolves the `Color`
/// through `NSColor` against both appearances and asserts the two
/// readings actually differ.
@Suite("StanfordTheme dark-mode")
struct ThemeTests {

    /// Pulls the sRGB components out of a `SwiftUI.Color` by rendering
    /// it through `NSColor` under the given appearance. Returns `nil`
    /// only if the color genuinely fails to resolve.
    private func resolve(_ color: Color, appearance: NSAppearance.Name) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let ns = NSColor(color)
        let app = NSAppearance(named: appearance)
        var comp: (r: CGFloat, g: CGFloat, b: CGFloat)?
        app?.performAsCurrentDrawingAppearance {
            if let srgb = ns.usingColorSpace(.sRGB) {
                comp = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
            }
        }
        return comp
    }

    private func approximatelyEqual(
        _ a: (r: CGFloat, g: CGFloat, b: CGFloat),
        _ b: (r: CGFloat, g: CGFloat, b: CGFloat),
        tolerance: CGFloat = 0.01
    ) -> Bool {
        abs(a.r - b.r) < tolerance
            && abs(a.g - b.g) < tolerance
            && abs(a.b - b.b) < tolerance
    }

    private func relativeLuminance(hex: UInt) -> Double {
        func channel(_ shift: UInt) -> Double {
            let srgb = Double((hex >> shift) & 0xFF) / 255.0
            return srgb <= 0.03928
                ? srgb / 12.92
                : pow((srgb + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrastRatio(_ foreground: UInt, _ background: UInt) -> Double {
        let first = relativeLuminance(hex: foreground)
        let second = relativeLuminance(hex: background)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test("Brand colors resolve to different values in light vs dark")
    func brandColorsAreDarkModeAware() {
        let brandColors: [(String, Color)] = [
            ("cardinalRed",    Stanford.cardinalRed),
            ("paloAltoGreen",  Stanford.paloAltoGreen),
            ("lagunita",       Stanford.lagunita),
            ("poppy",          Stanford.poppy),
            ("illuminating",   Stanford.illuminating),
            ("plum",           Stanford.plum),
            ("sky",            Stanford.sky),
            ("bay",            Stanford.bay),
            ("sandstone",      Stanford.sandstone),
            ("stone",          Stanford.stone),
            ("driftwood",      Stanford.driftwood)
        ]
        for (name, color) in brandColors {
            guard
                let light = resolve(color, appearance: .aqua),
                let dark  = resolve(color, appearance: .darkAqua)
            else {
                Issue.record("Failed to resolve \(name)")
                continue
            }
            #expect(
                !approximatelyEqual(light, dark),
                "\(name) renders identically in light and dark; dark variant is missing"
            )
        }
    }

    @Test("Cardinal red light hex is the official Stanford cardinal 0x8C1515")
    func cardinalRedLightPinned() {
        guard let light = resolve(Stanford.cardinalRed, appearance: .aqua) else {
            Issue.record("Could not resolve cardinalRed")
            return
        }
        let expected: (CGFloat, CGFloat, CGFloat) = (0x8C / 255, 0x15 / 255, 0x15 / 255)
        #expect(approximatelyEqual(light, expected))
    }

    @Test("Semantic status aliases point at semantic tokens")
    func semanticStatusAliasesAreBranded() {
        // Status aliases should resolve to their explicit semantic tokens.
        // Error intentionally diverges from Cardinal Red so brand and failure
        // states do not collide.
        let pairs: [(String, Color, Color)] = [
            ("statusHealthy", Stanford.statusHealthy, Stanford.paloAltoGreen),
            ("statusWarn",    Stanford.statusWarn,    Stanford.poppy),
            ("statusError",   Stanford.statusError,   Stanford.errorRed),
            ("statusInfo",    Stanford.statusInfo,    Stanford.sky)
        ]
        for (name, alias, base) in pairs {
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                guard
                    let a = resolve(alias, appearance: appearance),
                    let b = resolve(base, appearance: appearance)
                else {
                    Issue.record("Could not resolve \(name)")
                    continue
                }
                #expect(
                    approximatelyEqual(a, b),
                    "\(name) does not match its underlying brand in \(appearance)"
                )
            }
        }
    }

    @Test("Chat reading text meets paragraph contrast targets")
    func chatReadingTextMeetsContrastTargets() {
        // Dark mode is checked against the real content surface
        // (warmCanvasDarkHex ≈ textBackgroundColor / cardBackground, where
        // reading text sits), not pure black — black is misleadingly lenient
        // for light-on-dark text.
        #expect(contrastRatio(Stanford.readingTextLightHex, 0xFFFFFF) >= 4.5)
        #expect(contrastRatio(Stanford.readingTextLightHex, Stanford.warmCanvasLightHex) >= 4.5)
        #expect(contrastRatio(Stanford.readingTextDarkHex, Stanford.warmCanvasDarkHex) >= 4.5)
    }

    @Test("Low-emphasis text tokens clear WCAG AA (4.5:1) in both modes")
    func secondaryTextMeetsContrastTargets() {
        // Both tokens back small (10–12pt) normal-weight text, so both must
        // clear AA (4.5:1) — there's no large-text 3:1 exemption here. Dark
        // mode is checked against the representative dark content surface
        // (warmCanvasDarkHex), NOT pure black: light-on-dark text has its
        // LOWEST contrast on the lightest real surface, so black would be a
        // misleadingly lenient reference.
        #expect(contrastRatio(Stanford.textSecondaryLightHex, 0xFFFFFF) >= 4.5)
        #expect(contrastRatio(Stanford.textSecondaryLightHex, Stanford.warmCanvasLightHex) >= 4.5)
        #expect(contrastRatio(Stanford.textSecondaryDarkHex, Stanford.warmCanvasDarkHex) >= 4.5)

        #expect(contrastRatio(Stanford.textTertiaryLightHex, 0xFFFFFF) >= 4.5)
        #expect(contrastRatio(Stanford.textTertiaryLightHex, Stanford.warmCanvasLightHex) >= 4.5)
        #expect(contrastRatio(Stanford.textTertiaryDarkHex, Stanford.warmCanvasDarkHex) >= 4.5)
    }

    @Test("The interaction accent is one hue (interactive == focusRing == link == lagunita)")
    func interactionAccentIsUnified() {
        // A0/A2: the scene-level tint and every interactive control should
        // resolve to a single accent. cardinalRed is reserved for the brand
        // mark and errors, so it must NOT be the interaction accent.
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            guard
                let interactive = resolve(Stanford.interactive, appearance: appearance),
                let focusRing = resolve(Stanford.focusRing, appearance: appearance),
                let link = resolve(Stanford.link, appearance: appearance),
                let lagunita = resolve(Stanford.lagunita, appearance: appearance),
                let cardinal = resolve(Stanford.cardinalRed, appearance: appearance)
            else {
                Issue.record("Could not resolve accent tokens in \(appearance)")
                continue
            }
            #expect(approximatelyEqual(interactive, focusRing), "interactive != focusRing in \(appearance)")
            #expect(approximatelyEqual(interactive, link), "interactive != link in \(appearance)")
            #expect(approximatelyEqual(interactive, lagunita), "interactive != lagunita in \(appearance)")
            #expect(!approximatelyEqual(interactive, cardinal), "interactive must not be cardinalRed in \(appearance)")
        }
    }

    @Test("Bundled Stanford typography fonts are packaged")
    func bundledTypographyFontsArePackaged() {
        let filenames = Set(StanfordFontRegistrar.bundledFontURLs().map(\.lastPathComponent))

        #expect(filenames == Set(StanfordFontRegistrar.bundledFontResourceNames))
    }
}

@Suite("AppearancePreference")
struct AppearancePreferenceTests {
    @Test("system maps to nil ColorScheme")
    func systemIsUnmanaged() {
        #expect(AppearancePreference.system.colorScheme == nil)
    }

    @Test("light / dark map to their ColorScheme cases")
    func explicitModesResolve() {
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test("Raw values round-trip through AppStorage")
    func rawValuesRoundTrip() {
        for p in AppearancePreference.allCases {
            let reconstructed = AppearancePreference(rawValue: p.rawValue)
            #expect(reconstructed == p)
        }
    }

    @Test("Labels and symbols are non-empty")
    func metadataPresent() {
        for p in AppearancePreference.allCases {
            #expect(!p.label.isEmpty)
            #expect(!p.symbolName.isEmpty)
        }
    }
}
