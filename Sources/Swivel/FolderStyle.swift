import AppKit
import CoreText
import UniformTypeIdentifiers

/// How a restyled folder looks: a tint over the system folder and an optional symbol or emoji on its front.
/// A picture is chosen per session and is not part of a saved (recent) style.
struct FolderStyle: Codable, Equatable, Sendable {
    enum Badge: String, Codable, Sendable { case none, symbol, emoji }

    /// Opaque sRGB as "RRGGBB", or nil to keep the system folder's own colour.
    var tint: String?
    var material: FolderMaterial = .plain
    var badge: Badge = .none
    var symbol = "star.fill"
    var emoji = "⭐️"
    /// Lettering on the folder's front; empty for none.
    var text = ""

    init(tint: String? = nil, material: FolderMaterial = .plain) {
        self.tint = tint
        self.material = material
    }

    // Decoded field by field, so recents saved before a field existed still load.
    private enum CodingKeys: String, CodingKey { case tint, material, badge, symbol, emoji, text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        material = (try? c.decodeIfPresent(FolderMaterial.self, forKey: .material)) ?? .plain
        badge = (try? c.decodeIfPresent(Badge.self, forKey: .badge)) ?? .none
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "star.fill"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "⭐️"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    /// The lettering as drawn: at most 24 characters on at most two lines.
    var drawnText: String {
        let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard words.count > 10, let space = words.split(separator: " ").count > 1 ? words.middleSpace : nil else { return words }
        var lines = words
        lines.replaceSubrange(space...space, with: "\n")
        return lines
    }

    /// The symbols offered in the editor, with their English names.
    static let symbols: [(name: String, title: String)] = [
        ("star.fill", "Star"), ("heart.fill", "Heart"), ("briefcase.fill", "Work"), ("house.fill", "Home"),
        ("photo.fill", "Photos"), ("camera.fill", "Camera"), ("film.fill", "Movies"), ("music.note", "Songs"),
        ("doc.text.fill", "Documents"), ("book.fill", "Books"), ("graduationcap.fill", "School"),
        ("chevron.left.forwardslash.chevron.right", "Code"), ("hammer.fill", "Tools"), ("paintbrush.fill", "Design"),
        ("gamecontroller.fill", "Games"), ("cart.fill", "Shopping"), ("airplane", "Travel"), ("tray.full.fill", "Archive"),
        ("lock.fill", "Private"), ("cloud.fill", "Cloud"), ("arrow.down.circle.fill", "Downloads"), ("flag.fill", "Flag"),
    ]

    /// The colours offered in the editor; nil is the system folder unchanged.
    static let colors: [(title: String, hex: String?)] = [
        ("Original Color", nil), ("Red", "E5484D"), ("Orange", "F2843A"), ("Yellow", "F2C230"), ("Green", "3FAE5A"),
        ("Mint", "3CC8B4"), ("Teal", "2FA6C6"), ("Blue", "3D82F0"), ("Indigo", "5B5BD6"), ("Purple", "9B5DE5"),
        ("Pink", "EC6AA8"), ("Brown", "A57A55"), ("Gray", "8E8E93"), ("Graphite", "4A4A4F"),
    ]

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// The emoji as drawn: its first character only, so a pasted sentence can't overflow the folder.
    var drawnEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map(String.init) ?? ""
    }
}

private extension String {
    /// The space nearest the middle, for breaking a short title into two lines.
    var middleSpace: String.Index? {
        let middle = count / 2
        return indices.filter { self[$0] == " " }.min { abs(distance(from: startIndex, to: $0) - middle) < abs(distance(from: startIndex, to: $1) - middle) }
    }
}

/// Draws restyled folder icons and puts them on folders.
@MainActor
enum FolderIcons {
    static let maxRecents = 6
    nonisolated static let pixelSize = 1024

    /// The system's own folder icon, upright, at `size` pixels.
    static func baseIcon(size: Int = pixelSize) -> CGImage? {
        let icon = NSWorkspace.shared.icon(for: .folder)
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let picked = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        // The best representation may be smaller or larger; draw it into an exact square.
        guard let ctx = context(size) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(picked, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// A symbol's shape as a template image (alpha only), `points` tall.
    static func symbolImage(_ name: String, points: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    nonisolated static func context(_ size: Int) -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The finished icon. `picture` goes on the folder's front, or replaces the folder when `pictureFills`.
    static func render(_ style: FolderStyle, base: CGImage, picture: CGImage? = nil, pictureFills: Bool = false,
                       size: Int = pixelSize) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.interpolationQuality = .high
        if let picture, pictureFills {
            let fitted = fit(CGSize(width: picture.width, height: picture.height), in: full.insetBy(dx: CGFloat(size) * 0.06, dy: CGFloat(size) * 0.06))
            ctx.addPath(CGPath(roundedRect: fitted, cornerWidth: fitted.width * 0.08, cornerHeight: fitted.width * 0.08, transform: nil))
            ctx.clip()
            ctx.draw(picture, in: fitted)
            return ctx.makeImage()
        }
        let tint = style.tint.flatMap(FolderStyle.rgb)
        let folder: CGImage? = switch style.material {
        case .plain: tint.flatMap { tinted(base, $0, size: size) } ?? base
        default: materialTexture(style, tint: tint, size: size).flatMap { shaded(base, texture: $0, size: size) }
        }
        ctx.draw(folder ?? base, in: full)

        // The front of the folder, where macOS puts its own symbols. Lettering takes its lower part.
        let s = CGFloat(size)
        var front = CGRect(x: s * 0.2, y: s * 0.22, width: s * 0.6, height: s * 0.42)
        let lettering = style.drawnText
        if !lettering.isEmpty {
            let hasBadge = picture != nil || style.badge != .none
            let area = hasBadge ? CGRect(x: s * 0.12, y: s * 0.18, width: s * 0.76, height: s * 0.2)
                                : CGRect(x: s * 0.12, y: s * 0.22, width: s * 0.76, height: s * 0.4)
            drawLettering(lettering, material: style.material, in: area, ctx: ctx, s: s)
            if hasBadge { front = CGRect(x: s * 0.25, y: s * 0.39, width: s * 0.5, height: s * 0.27) }
        }
        if let picture {
            let bounds = front.insetBy(dx: s * 0.02, dy: 0)
            let fill = aspectFill(CGSize(width: picture.width, height: picture.height), in: bounds)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
            ctx.clip()
            ctx.draw(picture, in: fill)
            ctx.restoreGState()
            return ctx.makeImage()
        }
        switch style.badge {
        case .none: break
        case .symbol:
            guard let shape = symbolImage(style.symbol, points: 200) else { break }
            let box = fit(CGSize(width: shape.width, height: shape.height), in: front.insetBy(dx: s * 0.12, dy: s * 0.04))
            // Embossed like Finder's own folder symbols: the folder's colour, darker.
            let (r, g, b) = badgeColor(style)
            ctx.saveGState()
            ctx.clip(to: box, mask: alphaMask(shape) ?? shape)
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 0.9))
            ctx.fill(box)
            ctx.restoreGState()
        case .emoji:
            let text = style.drawnEmoji
            guard !text.isEmpty else { break }
            let font = CTFontCreateWithName("Apple Color Emoji" as CFString, s * 0.36, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            ctx.textPosition = .zero
            let bounds = CTLineGetImageBounds(line, ctx)
            let scale = min(1, front.width * 0.8 / max(bounds.width, 1), front.height * 0.85 / max(bounds.height, 1))
            ctx.saveGState()
            ctx.translateBy(x: front.midX, y: front.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Textures are drawn once per material, colour, emoji and size.
    private static var textures: [String: CGImage] = [:]

    static func materialTexture(_ style: FolderStyle, tint: (r: Double, g: Double, b: Double)?, size: Int) -> CGImage? {
        let usedTint = style.material.usesTint ? tint : nil
        let emoji = style.material == .emojiPattern ? style.drawnEmoji : ""
        let key = "\(style.material.rawValue)|\(usedTint.map { "\($0)" } ?? "-")|\(emoji)|\(size)"
        if let cached = textures[key] { return cached }
        let image = style.material.draw(size: size, tint: usedTint, emoji: emoji)
        if textures.count > 64 { textures.removeAll() }
        textures[key] = image
        return image
    }

    /// Text fitted into `area`, one or two centred lines, in the material's lettering.
    static func drawLettering(_ text: String, material: FolderMaterial, in area: CGRect, ctx: CGContext, s: CGFloat) {
        let (fontName, scale, color) = material.lettering
        let lines = text.components(separatedBy: "\n")
        var size = area.height / CGFloat(lines.count) * 0.82 * scale
        func makeLines(_ size: CGFloat) -> [CTLine] {
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            return lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color])) }
        }
        var built = makeLines(size)
        ctx.textPosition = .zero
        let widest = built.map { CTLineGetImageBounds($0, ctx).width }.max() ?? 0
        if widest > area.width { size *= area.width / widest; built = makeLines(size) }
        let lineHeight = size * 1.05
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.004), blur: s * 0.006, color: CGColor(gray: 0, alpha: 0.25))
        for (i, line) in built.enumerated() {
            // Image bounds are measured from the context's current text position.
            ctx.textPosition = .zero
            let bounds = CTLineGetImageBounds(line, ctx)
            let centreY = area.midY + (CGFloat(built.count - 1) / 2 - CGFloat(i)) * lineHeight
            ctx.textPosition = CGPoint(x: area.midX - bounds.midX, y: centreY - bounds.midY)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// The folder made of `texture`: the folder's alpha, and its brightness relative to typical scaling the texture
    /// (highlights lean a little toward white), so tab, front and edges keep their depth.
    nonisolated static func shaded(_ base: CGImage, texture: CGImage, size: Int) -> CGImage? {
        guard let ctx = context(size), let data = ctx.data, let tex = context(size), let texData = tex.data else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))
        tex.draw(texture, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let t = texData.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let count = size * size
        var sum = 0.0, weight = 0.0
        for i in 0..<count {
            let a = Double(pixels[i * 4 + 3])
            guard a > 0 else { continue }
            sum += (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / a * a
            weight += a
        }
        guard weight > 0 else { return ctx.makeImage() }
        let reference = max(sum / weight, 0.05)
        for i in 0..<count {
            let a = Double(pixels[i * 4 + 3])
            guard a > 0 else { continue }
            let l = (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / a
            let ratio = l / reference
            for k in 0..<3 {
                let c = Double(t[i * 4 + k]) / 255
                let v = ratio <= 1 ? c * (0.35 + 0.65 * ratio) : c + (1 - c) * 0.5 * min(1, (ratio - 1) / max(1 / reference - 1, 0.01))
                pixels[i * 4 + k] = UInt8((min(max(v, 0), 1) * a).rounded())
            }
        }
        return ctx.makeImage()
    }

    nonisolated static func aspectFill(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// The darker shade a symbol is drawn in.
    nonisolated static func badgeColor(_ style: FolderStyle) -> (Double, Double, Double) {
        if style.material != .plain, style.material != .emojiPattern,
           let c = style.material.lettering.color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
           c.count >= 3 {
            return (Double(c[0]), Double(c[1]), Double(c[2]))
        }
        let (r, g, b) = style.tint.flatMap(FolderStyle.rgb) ?? (0.27, 0.6, 0.9)
        // On a dark folder a darker symbol disappears; it is lighter instead.
        if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.35 { return (r + (1 - r) * 0.45, g + (1 - g) * 0.45, b + (1 - b) * 0.45) }
        return (r * 0.62, g * 0.62, b * 0.62)
    }

    /// A gray mask from an image's alpha, for `clip(to:mask:)` (which reads gray, not alpha).
    nonisolated static func alphaMask(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let alpha = Data(bytes: data, count: w * h)
        guard let provider = CGDataProvider(data: alpha as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Recolours the folder while keeping its shading: each pixel's brightness relative to the folder's typical
    /// brightness scales the tint, and highlights brighter than typical lean toward white.
    nonisolated static func tinted(_ base: CGImage, _ tint: (r: Double, g: Double, b: Double), size: Int) -> CGImage? {
        guard let ctx = context(size), let data = ctx.data else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let count = size * size
        // Typical brightness: the alpha-weighted mean over the folder.
        var sum = 0.0, weight = 0.0
        for i in 0..<count {
            let a = Double(pixels[i * 4 + 3])
            guard a > 0 else { continue }
            let l = (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / a
            sum += l * a; weight += a
        }
        guard weight > 0 else { return ctx.makeImage() }
        let reference = max(sum / weight, 0.05)
        for i in 0..<count {
            let a = Double(pixels[i * 4 + 3])
            guard a > 0 else { continue }
            let l = (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2])) / a
            let ratio = l / reference
            let channels = [tint.r, tint.g, tint.b].map { c -> Double in
                ratio <= 1 ? c * ratio : c + (1 - c) * min(1, (ratio - 1) / max(1 / reference - 1, 0.01))
            }
            for (k, c) in channels.enumerated() { pixels[i * 4 + k] = UInt8((min(max(c, 0), 1) * a).rounded()) }
        }
        return ctx.makeImage()
    }

    /// A plain folder (not a symlink, package or app) whose icon may be changed.
    static func checkFolder(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isVolumeKey])
        guard values?.isSymbolicLink != true, values?.isDirectory == true else {
            throw ToolError(L("%@ isn't a folder.", url.lastPathComponent))
        }
        guard values?.isPackage != true else { throw ToolError(L("%@ is an app or package; its icon can't be changed here.", url.lastPathComponent)) }
        guard values?.isVolume != true else { throw ToolError(L("%@ is a disk; only folders can be restyled.", url.lastPathComponent)) }
    }

    /// The folder already has an icon of its own (Finder keeps it in a hidden `Icon\r` file inside).
    static func hasCustomIcon(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.appendingPathComponent("Icon\r").path, &info) == 0
    }

    /// Sets (or with nil, removes) the custom icon of each folder. Returns how many changed.
    static func apply(_ icon: CGImage?, to folders: [URL]) throws -> Int {
        for folder in folders { try checkFolder(folder) }
        let image = icon.map { NSImage(cgImage: $0, size: NSSize(width: 512, height: 512)) }
        var failed: [String] = []
        for folder in folders where !NSWorkspace.shared.setIcon(image, forFile: folder.path, options: []) {
            failed.append(folder.lastPathComponent)
        }
        if !failed.isEmpty {
            let changed = folders.count - failed.count
            throw ToolError(L("Couldn't change the icon of %@ (the folder may be locked or read-only).", failed.joined(separator: ", "))
                            + (changed > 0 ? " " + L("Changed %d other folders.", changed) : ""))
        }
        return folders.count
    }

    static var recents: [FolderStyle] {
        Prefs.folderStyleRecents
    }

    static func remember(_ style: FolderStyle) {
        guard style != FolderStyle() else { return }
        Prefs.folderStyleRecents = Array(([style] + recents.filter { $0 != style }).prefix(maxRecents))
    }
}

/// The wheel's "Change Style" for folders: colour, symbol or emoji, or a picture; one style for every dropped folder.
final class FolderStyleEditor: Editor {
    private let folders: [URL]
    private let preview = IconPreview()
    private var base: CGImage?
    private var picture: CGImage?
    private var mode: NSSegmentedControl!
    private var color: NSPopUpButton!
    private let colorWell = NSColorWell(style: .minimal)
    private var badge: NSSegmentedControl!
    private var symbol: NSPopUpButton!
    private let emoji = NSTextField(string: "⭐️")
    private var pictureButton: NSButton!
    private var pictureFills: NSButton!
    private let pictureName = NSTextField(labelWithString: "")
    private var rows: [NSView] = []
    private let recentsRow = NSStackView()
    private var symbolRow: NSView!
    private var emojiRow: NSView!
    private var pictureRow: NSView!
    private var recentStyles: [FolderStyle] = []
    private var material: FolderMaterial = .plain
    private let text = NSTextField(string: "")
    private var libraryButtons: [NSButton] = []
    private var colorRow: NSView!

    init(folders: [URL]) throws {
        guard let first = folders.first else { throw ToolError(L("Drop a folder.")) }
        for folder in folders { try FolderIcons.checkFolder(folder) }
        self.folders = folders
        super.init(title: "Change Style", source: first, canvas: preview)
        if folders.count > 1 { window.subtitle = L("%d folders", folders.count) }

        mode = segments(["Custom Style", "macOS Default"])
        addRow("Icon", mode)

        recentsRow.spacing = 6
        addRow("Recent", recentsRow)
        addRow("Library", libraryGrid())

        color = popup(FolderStyle.colors.map(\.title) + ["Custom"])
        color.selectItem(at: FolderStyle.colors.firstIndex { $0.title == "Blue" } ?? 0)
        colorWell.color = .systemTeal
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)
        colorRow = makeRow("Color", [color, colorWell])
        controls.addArrangedSubview(colorRow)
        colorRow.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true

        text.placeholderString = L("Optional, e.g. POSTER DESIGN")
        text.delegate = self
        text.target = self
        text.action = #selector(controlChanged)
        addRow("Text", text)

        badge = segments(["No Badge", "Symbol", "Emoji", "Image"])
        addRow("On the Folder", badge)

        symbol = NSPopUpButton(frame: .zero, pullsDown: false)
        for entry in FolderStyle.symbols {
            symbol.addItem(withTitle: L(entry.title))
            symbol.lastItem?.image = NSImage(systemSymbolName: entry.name, accessibilityDescription: nil)
        }
        symbol.target = self
        symbol.action = #selector(controlChanged)
        symbolRow = makeRow("Symbol", [symbol])

        emoji.placeholderString = "😀"
        emoji.alignment = .center
        emoji.font = .systemFont(ofSize: 20)
        emoji.widthAnchor.constraint(equalToConstant: 60).isActive = true
        emoji.target = self
        emoji.action = #selector(controlChanged)
        emoji.delegate = self
        let emojiPicker = NSButton(title: L("Emoji & Symbols"), target: self, action: #selector(showEmojiPicker))
        emojiPicker.bezelStyle = .push
        emojiRow = makeRow("Emoji", [emoji, emojiPicker])

        pictureButton = NSButton(title: L("Choose Picture…"), target: self, action: #selector(choosePicture))
        pictureButton.bezelStyle = .push
        pictureFills = checkbox("Whole icon", false)
        pictureName.textColor = .secondaryLabelColor
        pictureName.lineBreakMode = .byTruncatingMiddle
        pictureRow = makeRow("Image", [pictureButton, pictureFills, pictureName])

        for row in [symbolRow!, emojiRow!, pictureRow!] {
            controls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }

        window.setContentSize(NSSize(width: 600, height: 860))
        window.minSize = NSSize(width: 540, height: 760)

        let existing = folders.filter(FolderIcons.hasCustomIcon).count
        if existing > 0 {
            let note = NSTextField(wrappingLabelWithString: existing == folders.count && existing == 1
                ? L("This folder already has its own icon; applying replaces it.")
                : L("%d of these folders already have their own icon; applying replaces it.", existing))
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            controls.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
    }

    override func load() async throws {
        guard let base = FolderIcons.baseIcon() else { throw ToolError(L("Couldn't read the system folder icon.")) }
        self.base = base
        rebuildRecents()
        drawLibrary()
    }

    private var style: FolderStyle {
        var style = FolderStyle()
        let index = color.indexOfSelectedItem
        style.tint = index < FolderStyle.colors.count ? FolderStyle.colors[max(index, 0)].hex : FolderStyle.hex(colorWell.color)
        style.badge = [.none, .symbol, .emoji, .none][max(badge.selectedSegment, 0)]
        style.symbol = FolderStyle.symbols[max(symbol.indexOfSelectedItem, 0)].name
        style.emoji = emoji.stringValue
        style.material = material
        style.text = text.stringValue
        return style
    }

    private var usesPicture: Bool { badge.selectedSegment == 3 && picture != nil }

    private func set(_ style: FolderStyle) {
        if let tint = style.tint, let index = FolderStyle.colors.firstIndex(where: { $0.hex == tint }) {
            color.selectItem(at: index)
        } else if let tint = style.tint, let (r, g, b) = FolderStyle.rgb(tint) {
            color.selectItem(at: FolderStyle.colors.count)
            colorWell.color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        } else {
            color.selectItem(at: 0)
        }
        badge.selectedSegment = [FolderStyle.Badge.none: 0, .symbol: 1, .emoji: 2][style.badge] ?? 0
        symbol.selectItem(at: FolderStyle.symbols.firstIndex { $0.name == style.symbol } ?? 0)
        emoji.stringValue = style.emoji
        material = style.material
        text.stringValue = style.text
        mode.selectedSegment = 0
        highlightLibrary(nil)
    }

    /// Every library style as a small button, eight to a row, scrolling.
    private func libraryGrid() -> NSView {
        let columns = 8, cell: CGFloat = 50
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        grid.xPlacement = .leading
        var row: [NSView] = []
        for (i, entry) in FolderLibrary.entries.enumerated() {
            let button = NSButton(image: NSImage(), target: self, action: #selector(libraryClicked))
            button.tag = i
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = L(entry.title)
            button.setAccessibilityLabel(L(entry.title))
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.widthAnchor.constraint(equalToConstant: cell).isActive = true
            button.heightAnchor.constraint(equalToConstant: cell).isActive = true
            libraryButtons.append(button)
            row.append(button)
            if row.count == columns { grid.addRow(with: row); row = [] }
        }
        if !row.isEmpty { grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: columns - row.count)) }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            grid.topAnchor.constraint(equalTo: flipped.topAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: cell * 2 + 4 + 8),
            scroll.widthAnchor.constraint(equalToConstant: CGFloat(columns) * (cell + 4) + 16),
        ])
        return scroll
    }

    private func drawLibrary() {
        guard let base else { return }
        for (i, entry) in FolderLibrary.entries.enumerated() {
            var style = entry.style
            if style.material == .plain { style.tint = self.style.tint }
            libraryButtons[i].image = FolderIcons.render(style, base: base, size: 128).map { NSImage(cgImage: $0, size: NSSize(width: 48, height: 48)) }
        }
    }

    private func highlightLibrary(_ index: Int?) {
        for (i, button) in libraryButtons.enumerated() {
            button.layer?.backgroundColor = i == index ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        }
    }

    /// A material alone keeps the badge and text already chosen; a combination brings its own.
    @objc private func libraryClicked(_ sender: NSButton) {
        guard FolderLibrary.entries.indices.contains(sender.tag) else { return }
        let entry = FolderLibrary.entries[sender.tag].style
        mode.selectedSegment = 0
        material = entry.material
        if let tint = entry.tint { set(tint: tint) }
        if entry.badge != .none {
            badge.selectedSegment = entry.badge == .symbol ? 1 : 2
            emoji.stringValue = entry.emoji
        } else if entry.material == .emojiPattern {
            emoji.stringValue = entry.emoji
        }
        if !entry.text.isEmpty { text.stringValue = entry.text }
        highlightLibrary(sender.tag)
        controlChanged(sender)
    }

    private func set(tint: String) {
        if let index = FolderStyle.colors.firstIndex(where: { $0.hex == tint }) {
            color.selectItem(at: index)
        } else if let (r, g, b) = FolderStyle.rgb(tint) {
            color.selectItem(at: FolderStyle.colors.count)
            colorWell.color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    private func rebuildRecents() {
        recentStyles = FolderIcons.recents
        for view in recentsRow.arrangedSubviews { view.removeFromSuperview() }
        guard let base, !recentStyles.isEmpty else {
            let none = NSTextField(labelWithString: L("Styles you apply appear here."))
            none.textColor = .secondaryLabelColor
            recentsRow.addArrangedSubview(none)
            return
        }
        for (i, style) in recentStyles.enumerated() {
            let image = FolderIcons.render(style, base: base, size: 96).map { NSImage(cgImage: $0, size: NSSize(width: 34, height: 34)) }
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(recentClicked))
            button.tag = i
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.setAccessibilityLabel(L("Recent style %d", i + 1))
            recentsRow.addArrangedSubview(button)
        }
    }

    @objc private func recentClicked(_ sender: NSButton) {
        guard recentStyles.indices.contains(sender.tag) else { return }
        set(recentStyles[sender.tag])
        controlChanged(sender)
    }

    @objc private func colorWellChanged(_ sender: Any?) {
        color.selectItem(at: FolderStyle.colors.count)
        controlChanged(sender)
    }

    @objc private func showEmojiPicker() {
        window.makeFirstResponder(emoji)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                self.picture = try Images.load(url, maxPixels: FolderIcons.pixelSize)
                self.pictureName.stringValue = url.lastPathComponent
                self.badge.selectedSegment = 3
                self.controlChanged(nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window, completionHandler: nil)
            }
        }
    }

    private func icon(size: Int) -> CGImage? {
        guard let base else { return nil }
        if mode.selectedSegment == 1 { return base }
        return FolderIcons.render(style, base: base, picture: usesPicture ? picture : nil,
                                  pictureFills: pictureFills.state == .on, size: size)
    }

    override func update() {
        let custom = mode.selectedSegment == 0
        for control in [badge!, symbol!, pictureButton!, pictureFills!, text] as [NSControl] { control.isEnabled = custom }
        for button in libraryButtons { button.isEnabled = custom }
        emoji.isEnabled = custom
        // Most materials have colours of their own.
        color.isEnabled = custom && material.usesTint
        colorWell.isEnabled = color.isEnabled
        colorWell.isHidden = color.indexOfSelectedItem < FolderStyle.colors.count
        symbolRow.isHidden = badge.selectedSegment != 1
        emojiRow.isHidden = badge.selectedSegment != 2
        pictureRow.isHidden = badge.selectedSegment != 3
        pictureFills.isEnabled = custom && picture != nil
        preview.image = icon(size: 512)
        if let base, let plain = libraryButtons.first {
            plain.image = FolderIcons.render(FolderStyle(tint: style.tint), base: base, size: 128).map { NSImage(cgImage: $0, size: NSSize(width: 48, height: 48)) }
        }
    }

    override func reset() {
        set(FolderStyle(tint: FolderStyle.colors.first { $0.title == "Blue" }?.hex))
        picture = nil
        pictureName.stringValue = ""
        pictureFills.state = .off
        material = .plain
        text.stringValue = ""
        highlightLibrary(nil)
    }

    override func apply() async throws -> [URL] {
        if mode.selectedSegment == 1 {
            _ = try FolderIcons.apply(nil, to: folders)
            return folders
        }
        if badge.selectedSegment == 3 && picture == nil { throw ToolError(L("Choose a picture first.")) }
        guard let icon = icon(size: FolderIcons.pixelSize) else { throw ToolError(L("Couldn't draw the icon.")) }
        _ = try FolderIcons.apply(icon, to: folders)
        if !usesPicture { FolderIcons.remember(style) }
        return folders
    }

    var restoredDefault: Bool { mode.selectedSegment == 1 }
}

/// Lays the library grid out from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An icon shown whole and aspect-fit; icons carry their own margin and shadow, so none is added.
final class IconPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contentsGravity = .resizeAspect
        layer?.contents = image
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension FolderStyleEditor: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { controlChanged(obj.object) }
}
