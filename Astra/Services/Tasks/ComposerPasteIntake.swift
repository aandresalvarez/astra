import AppKit

struct ComposerPasteIntakeResult: Equatable {
    let handled: Bool
    let attachmentPaths: [String]
}

enum ComposerPasteIntake {
    static let longTextLineThreshold = 10
    static let longTextCharacterThreshold = 500

    static func shouldAttachText(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).count > longTextLineThreshold
            || text.count > longTextCharacterThreshold
    }

    static func textAttachmentExtension(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? "json" : "txt"
    }

    static func intake(
        pasteboard: NSPasteboard = .general,
        existingAttachments: Set<String>
    ) -> ComposerPasteIntakeResult {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let newPaths = urls.map(\.path).filter { !existingAttachments.contains($0) }
            return ComposerPasteIntakeResult(handled: true, attachmentPaths: newPaths)
        }

        let types = pasteboard.types ?? []
        if types.contains(.png) || types.contains(.tiff),
           let image = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = image.first,
           let png = pngData(from: first) {
            let url = temporaryPasteURL(fileExtension: "png")
            try? png.write(to: url)
            return ComposerPasteIntakeResult(handled: true, attachmentPaths: [url.path])
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            guard shouldAttachText(text) else {
                return ComposerPasteIntakeResult(handled: false, attachmentPaths: [])
            }
            let url = temporaryPasteURL(fileExtension: textAttachmentExtension(for: text))
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return ComposerPasteIntakeResult(handled: true, attachmentPaths: [url.path])
        }

        return ComposerPasteIntakeResult(handled: false, attachmentPaths: [])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func temporaryPasteURL(fileExtension pathExtension: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra_paste_\(UUID().uuidString.prefix(8)).\(pathExtension)")
    }
}
