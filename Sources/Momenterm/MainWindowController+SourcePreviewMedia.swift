import AppKit

// Source preview language and image rendering helpers.
extension MainWindowController {
    // The language used to syntax-highlight a file's RAW source. SVG is XML; the
    // rendered languages keep their own highlighting; everything else is passed
    // through unchanged.
    func rawPreviewLanguage(for language: String) -> String {
        language == "svg" ? "xml" : language
    }

    func sourcePreviewRenderedLine(path _: String, contentLine: Int) -> Int {
        max(contentLine, 1)
    }
    func renderImagePreview(_ image: NSImage) {
        overlayDiffSplitView.isHidden = true
        overlaySettingsScrollView.isHidden = true
        sourcePreviewScrollView.isHidden = false
        sourcePreviewImageView.image = image

        let viewport = sourcePreviewScrollView.contentView.bounds.size
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 320, height: 240)
        let maxWidth = max(viewport.width - 48, 1)
        let maxHeight = max(viewport.height - 48, 1)
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        let displaySize = NSSize(width: max(1, imageSize.width * scale), height: max(1, imageSize.height * scale))
        let documentSize = NSSize(width: max(viewport.width, displaySize.width + 48), height: max(viewport.height, displaySize.height + 48))
        sourcePreviewDocumentView.frame = NSRect(origin: .zero, size: documentSize)
        sourcePreviewImageView.frame = NSRect(
            x: max(24, (documentSize.width - displaySize.width) / 2),
            y: max(24, (documentSize.height - displaySize.height) / 2),
            width: displaySize.width,
            height: displaySize.height
        )
    }
    func isNativeImagePreviewPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
            ".tif", ".tiff", ".heic", ".heif", ".ico", ".icns",
            ".svg", ".pdf", ".avif", ".apng"
        ].contains { lower.hasSuffix($0) }
    }
}
