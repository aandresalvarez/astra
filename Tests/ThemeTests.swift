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
        #expect(contrastRatio(Stanford.readingTextLightHex, 0xFFFFFF) >= 4.5)
        #expect(contrastRatio(Stanford.readingTextLightHex, Stanford.warmCanvasLightHex) >= 4.5)
        #expect(contrastRatio(Stanford.readingTextDarkHex, 0x000000) >= 4.5)
    }

    @Test("Warm light surfaces keep primary and secondary text readable")
    func warmLightSurfacesMeetContrastTargets() {
        // Primary text must clear WCAG AA (4.5:1) on every warm light surface
        // in the elevation ramp.
        let surfaces: [(String, UInt)] = [
            ("card",        Stanford.cardBackgroundLightHex),
            ("canvas",      Stanford.warmCanvasLightHex),
            ("control well", Stanford.controlWellLightHex),
            ("sidebar",     Stanford.sidebarBackgroundLightHex)
        ]
        for (name, surface) in surfaces {
            #expect(
                contrastRatio(Stanford.readingTextLightHex, surface) >= 4.5,
                "primary text fails AA on \(name) surface"
            )
            // Secondary text is used for subtitles/metadata; hold it to AA as
            // well so muted copy stays legible on the lightest card surface.
            #expect(
                contrastRatio(Stanford.textSecondaryLightHex, surface) >= 4.5,
                "secondary text fails AA on \(name) surface"
            )
        }
    }

    @Test("Warm light elevation ramp stays ordered and distinct")
    func warmLightSurfacesAreLayered() {
        // Cards sit above the canvas, which sits above the recessed chrome.
        // Each step must be perceptibly lighter than the one beneath it.
        let card = relativeLuminance(hex: Stanford.cardBackgroundLightHex)
        let canvas = relativeLuminance(hex: Stanford.warmCanvasLightHex)
        let well = relativeLuminance(hex: Stanford.controlWellLightHex)
        let sidebar = relativeLuminance(hex: Stanford.sidebarBackgroundLightHex)

        #expect(card > canvas, "card should be lighter than canvas")
        #expect(canvas > well, "canvas should be lighter than the control well")
        #expect(well > sidebar, "control well should be lighter than the sidebar")
        // The brightest surface stays off pure white to reduce eye strain.
        #expect(card < relativeLuminance(hex: 0xFFFFFF), "card should not be pure white")
    }

    @Test("Warm surface tokens defer to system colors in dark mode")
    func warmSurfaceTokensPreserveDarkMode() {
        let tokens: [(String, Color, NSColor)] = [
            ("fog",               Stanford.fog,              .controlBackgroundColor),
            ("panelBackground",   Stanford.panelBackground,  .windowBackgroundColor),
            ("cardBackground",    Stanford.cardBackground,   .textBackgroundColor),
            ("sidebarBackground", Stanford.sidebarBackground, .underPageBackgroundColor)
        ]
        for (name, token, system) in tokens {
            guard
                let resolved = resolve(token, appearance: .darkAqua),
                let reference = resolve(Color(nsColor: system), appearance: .darkAqua)
            else {
                Issue.record("Could not resolve \(name)")
                continue
            }
            #expect(
                approximatelyEqual(resolved, reference),
                "\(name) diverged from its system color in dark mode"
            )
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
