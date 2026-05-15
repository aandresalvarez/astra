import CoreText
import Foundation

enum StanfordFontRegistrar {
    static let bundledFontResourceNames = [
        "SourceSans3[wght].ttf",
        "SourceSerif4[opsz,wght].ttf",
        "RobotoMono[wght].ttf"
    ]

    static func bundledFontURLs(bundle: Bundle = AstraResourceBundle.current) -> [URL] {
        bundledFontResourceNames.compactMap { resourceName in
            bundle.url(forResource: resourceName, withExtension: nil, subdirectory: "Fonts")
                ?? bundle.url(forResource: "Fonts/\(resourceName)", withExtension: nil)
        }
    }

    static func registerBundledFonts(bundle: Bundle = AstraResourceBundle.current) {
        for url in bundledFontURLs(bundle: bundle) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let error = error?.takeRetainedValue() {
                if Int(CFErrorGetCode(error)) != CTFontManagerError.alreadyRegistered.rawValue {
                    AppLogger.audit(.appStarted, category: "Typography", fields: [
                        "font": url.lastPathComponent,
                        "error": (CFErrorCopyDescription(error) as String?) ?? "Font registration failed"
                    ])
                }
            }
        }
    }
}
