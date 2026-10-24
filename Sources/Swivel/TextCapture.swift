import AppKit
import Vision

enum TextRecognition {
    /// Input is an existing user-selected image. No screen capture is performed.
    static func recognize(_ url: URL) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try Images.load(url, maxPixels: 8000)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP"].filter(supported.contains)
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

@MainActor
final class TextCaptureWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static var open: [TextCaptureWindow] = []
    let window: NSWindow
    let text = CaptureTextView()
    /// Where Copy puts the text. Tests use a private pasteboard so they leave the user's clipboard alone.
    var pasteboard = NSPasteboard.general
    private let scroll = NSScrollView()
    private let preview = NSImageView()
    private let status = ToolUI.note("Recognizing text…")
    private let progress = NSProgressIndicator()
    private var copyButton: NSButton!
    private var task: Task<Void, Never>?
    /// Changes on every copy, so an older "Copied" can't put the title back early.
    private var copyGeneration = 0
    private var showingCopied = false

    static func present(_ url: URL) {
        guard Feature.textCapture.isOn else { return }
        let controller = TextCaptureWindow(url)
        open.append(controller)
        // The window comes up at once; the picture and the text fill in as they're ready.
        ToolUI.show(controller.window)
        controller.loadPreview(url)
        controller.recognize(url)
    }

    static func closeAll() { for controller in open { controller.window.close() } }

    /// Builds the window without showing it; `present` shows it and starts recognition.
    init(_ url: URL) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = L("Text Capture")
        window.subtitle = url.lastPathComponent
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel(L("Source image"))
        let well = NSBox()
        well.boxType = .custom
        well.borderColor = .separatorColor
        well.fillColor = .underPageBackgroundColor
        well.cornerRadius = 8
        well.contentView = preview

        text.font = .systemFont(ofSize: 15)
        text.isRichText = false
        text.allowsUndo = true
        text.isEditable = false
        text.delegate = self
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(L("Recognized text"))
        text.onCommandReturn = { [weak self] in self?.copyText() }
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let columns = ToolUI.stack([well, scroll], vertical: false, spacing: 16)
        columns.distribution = .fillEqually
        columns.alignment = .height

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        copyButton = ToolUI.button("Copy Text", target: self, action: #selector(copyText))
        copyButton.isEnabled = false
        copyButton.keyEquivalent = "\r"
        copyButton.toolTip = L("Press ⌘Return to copy while editing the text.")
        // The checkmark sits beside the title instead of at the edge of the (reserved) wider button.
        copyButton.imageHugsTitle = true
        ToolUI.reserveWidth(copyButton, for: [(L("Copy Text"), nil), (L("Copy Selection"), nil), (L("Copied"), Self.checkmark)])
        // Left alone, AppKit puts focus in the text when the window first appears (it's the only view that takes
        // focus), and there Return types a new line instead of reaching Copy. Starting on Copy keeps it off the
        // text; the button itself only takes focus with Full Keyboard Access, and otherwise the window keeps it.
        window.initialFirstResponder = copyButton
        let close = ToolUI.button("Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        let footer = NSStackView()
        footer.addView(ToolUI.stack([progress, status], vertical: false, spacing: 8), in: .leading)
        footer.addView(close, in: .trailing)
        footer.addView(copyButton, in: .trailing)
        let note = ToolUI.note("Review the recognized text before copying. You can edit it here.")
        let root = ToolUI.stack([columns, note, footer])
        let content = NSView()
        window.contentView = content
        ToolUI.embed(root, in: content)
        NSLayoutConstraint.activate([
            columns.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            note.widthAnchor.constraint(equalTo: root.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        columns.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private static let checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))

    /// Decodes the preview off the main thread (a large HEIC takes a noticeable moment) and fades it in.
    private func loadPreview(_ url: URL) {
        Task { [weak self] in
            guard let image = try? await Images.detached({ try Images.load(url, maxPixels: 1800) }), let self else { return }
            preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            ToolUI.fadeIn(preview)
        }
    }

    private func recognize(_ url: URL) {
        task = Task { [weak self] in
            do {
                let value = try await TextRecognition.recognize(url)
                guard !Task.isCancelled, let self else { return }
                showRecognized(value)
            } catch {
                guard !Task.isCancelled, let self else { return }
                progress.stopAnimation(nil)
                status.stringValue = L("Could not recognize text: %@", error.localizedDescription)
            }
        }
    }

    /// The text is ready to review. Focus stays off it, so Return copies straight away (Copy is the default button).
    /// Once the user clicks or tabs into the text, Return types a new line there and ⌘Return copies, as the Copy
    /// button's tooltip says.
    func showRecognized(_ value: String) {
        text.string = value
        text.isEditable = true
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollToBeginningOfDocument(nil)
        // A click into the empty box while waiting would otherwise leave focus there.
        if window.firstResponder === text { window.makeFirstResponder(nil) }
        status.stringValue = value.isEmpty ? L("No text found in this image.") : L("Ready to copy")
        progress.stopAnimation(nil)
        updateCopy()
        // Settle in softly.
        if !value.isEmpty { ToolUI.fadeIn(text, from: 0.4) }
    }

    func textDidChange(_ notification: Notification) { updateCopy() }
    func textViewDidChangeSelection(_ notification: Notification) { updateCopyTitle() }
    private func updateCopy() { copyButton.isEnabled = !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var selectedRanges: [NSRange] { text.selectedRanges.map(\.rangeValue).filter { $0.length > 0 } }

    /// "Copy Selection" while part of the text is selected; that's all that gets copied then.
    private func updateCopyTitle() {
        guard !showingCopied else { return }
        copyButton.image = nil
        copyButton.imagePosition = .noImage
        copyButton.title = L(selectedRanges.isEmpty ? "Copy Text" : "Copy Selection")
    }

    @objc private func copyText() {
        guard Feature.textCapture.isOn, copyButton.isEnabled else { return }
        let ranges = selectedRanges
        let value = ranges.isEmpty ? text.string : ranges.map { (text.string as NSString).substring(with: $0) }.joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        status.stringValue = L("Text copied")
        Feedback.done()
        // The button itself says it worked, for a moment.
        copyGeneration += 1
        let token = copyGeneration
        showingCopied = true
        copyButton.image = Self.checkmark
        copyButton.imagePosition = .imageLeading
        copyButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, copyGeneration == token else { return }
            showingCopied = false
            updateCopyTitle()
        }
    }
    @objc private func closeWindow() { window.close() }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        Self.open.removeAll { $0 === self }
        ToolUI.didClose()
    }
}

/// ⌘Return copies from anywhere in the window, including while the text is being edited, where plain Return
/// types a new line.
final class CaptureTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
