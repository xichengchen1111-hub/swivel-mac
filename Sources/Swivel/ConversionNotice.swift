import AppKit

/// Shared by the interactive entry points and the MCP plan preview. These describe intentional format losses.
enum ConversionNotice {
    static func messages(title: String, urls: [URL]) -> [String] {
        let kinds = Set(urls.map(FileKind.of))
        var notes: [String] = []
        if kinds.contains(.image) {
            if ["JPG", "HEIC", "WEBP", "AVIF"].contains(title) {
                notes.append("This format uses lossy compression. Fine image details may change.")
            }
            if ["JPG", "BMP"].contains(title) { notes.append("Transparent areas will become white.") }
            if title == "GIF" { notes.append("GIF uses a limited colour palette; smooth colours and transparency may change.") }
            if title == "PDF" { notes.append("Images are placed on PDF pages. Image metadata and advanced colour data may not be retained.") }
        }
        if kinds.contains(.document), Docs.formats.contains(where: { $0.name == title }) {
            notes.append("Document conversion preserves supported text and formatting. Complex Office layouts, comments, revisions, fields and embedded objects may be lost. PDF uses Letter pages; Markdown and HTML support is limited.")
        }
        if kinds.contains(.pdf) {
            if ["TXT", "DOCX", "RTF", "HTML"].contains(title) { notes.append("This extracts selectable text. Page layout, pictures and scanned text are not preserved.") }
            if title == "Compress" { notes.append("PDF compression reduces image quality and resolution. Keep the original for printing or archiving.") }
            if ["PNG", "JPG"].contains(title) { notes.append("PDF pages become images at up to 300 DPI. Text, links, forms and signatures will no longer be editable.") }
        }
        if kinds.contains(.video) {
            if title == "GIF" { notes.append("GIF exports the whole clip, up to 30 seconds, at 12 fps and up to 540 pixels. Sound is removed and colours are reduced.") }
            else if ["MP4", "MOV", "M4V", "HEVC", "1080p", "720p", "480p", "Compress", "Mute"].contains(title) {
                notes.append("Format-only video conversion copies compressed streams when supported; other cases re-encode. Quality, HDR, subtitles, metadata and additional tracks may change; keep the original.")
            }
            if ["WAV", "M4A", "Extract Audio"].contains(title) { notes.append("Only the first audio track is exported. Video, subtitles and other tracks are omitted.") }
        }
        if kinds.contains(.audio) || kinds.contains(.video), ["AAC", "M4A", "Extract Audio", "Mono", "Voice Memo"].contains(title) || kinds.contains(.audio) && title == "Compress" {
            notes.append("Audio is re-encoded with lossy AAC compression. Metadata may not be retained.")
        }
        if kinds.contains(.audio), ["WAV", "AIFF", "CAF", "FLAC", "ALAC"].contains(title) {
            notes.append("Audio precision is preserved where supported. Tags, artwork and other metadata may not be retained.")
        }
        if title == "TAR.GZ" { notes.append("TAR is a portable archive. Files with Mac resource forks or custom extended attributes must use ZIP instead.") }
        return notes
    }

    @MainActor static func confirm(title: String, urls: [URL]) throws {
        let notes = messages(title: title, urls: urls)
        guard !notes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("About this conversion")
        alert.informativeText = notes.map { L($0) }.joined(separator: "\n\n") + "\n\n" + L("The originals are kept unchanged.")
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { throw Cancelled() }
    }
}
