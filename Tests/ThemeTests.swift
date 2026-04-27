import Testing
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

    @Test("Semantic status aliases point at brand tokens")
    func semanticStatusAliasesAreBranded() {
        // statusHealthy / statusWarn / statusError / statusInfo must
        // resolve to the same pixels as their underlying brand colors —
        // they're not separate hues, just named roles.
        let pairs: [(String, Color, Color)] = [
            ("statusHealthy", Stanford.statusHealthy, Stanford.paloAltoGreen),
            ("statusWarn",    Stanford.statusWarn,    Stanford.poppy),
            ("statusError",   Stanford.statusError,   Stanford.cardinalRed),
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
