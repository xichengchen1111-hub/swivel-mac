import AppKit

/// Bounded, independent controls. A value of 1 preserves the 1.2 motion; colour/opacity never overshoot.
struct MotionTuning: Codable, Equatable {
    var speed: Double = 1
    var bounce: Double = 1

    var safeSpeed: CGFloat { CGFloat(speed.isFinite ? min(max(speed, 0.75), 1.5) : 1) }
    var safeBounce: CGFloat { CGFloat(bounce.isFinite ? min(max(bounce, 0), 1) : 1) }
    func damping(_ original: CGFloat) -> CGFloat { 1 - (1 - max(original, 0.6)) * safeBounce }
    var sanitized: Self { Self(speed: Double(safeSpeed), bounce: Double(safeBounce)) }
}

enum FeelArea: String, CaseIterable, Codable {
    case menu, clothesline, tools
    var title: String {
        switch self {
        case .menu: L("Pop-up menus")
        case .clothesline: L("Clothesline")
        case .tools: L("Tools & settings")
        }
    }
}

enum SoundStyle: String, CaseIterable, Codable {
    case classic, soft, bright
    var title: String {
        switch self {
        case .classic: L("Classic clicks")
        case .soft: L("Soft & low")
        case .bright: L("Bright chimes")
        }
    }
    var pitch: Double { self == .soft ? 0.72 : self == .bright ? 1.3 : 1 }
    var gain: Double { self == .soft ? 0.65 : self == .bright ? 0.85 : 1 }
}

enum TextSize: String, CaseIterable, Codable {
    case small, standard, large, extraLarge
    var title: String {
        switch self {
        case .small: L("Small")
        case .standard: L("Standard")
        case .large: L("Large")
        case .extraLarge: L("Extra Large")
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }
}

struct InteractionSettings: Codable, Equatable {
    var menu = MotionTuning()
    var clothesline = MotionTuning()
    var tools = MotionTuning()
    var soundStyle: SoundStyle = .classic
    var volume: Double = 1
    var hoverSound = true
    var gentleHaptics = false
    var textSize: TextSize = .standard
    var boldText = false

    subscript(_ area: FeelArea) -> MotionTuning {
        get {
            switch area {
            case .menu: menu
            case .clothesline: clothesline
            case .tools: tools
            }
        }
        set {
            switch area {
            case .menu: menu = newValue.sanitized
            case .clothesline: clothesline = newValue.sanitized
            case .tools: tools = newValue.sanitized
            }
        }
    }

    var sanitized: Self {
        var copy = self
        for area in FeelArea.allCases { copy[area] = self[area].sanitized }
        copy.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
        return copy
    }

    /// Presets change feel and sound, leaving reading preferences and the channel switches alone.
    mutating func apply(_ preset: FeelPreset) {
        let motion: MotionTuning
        switch preset {
        case .original: motion = MotionTuning()
        case .calm: motion = MotionTuning(speed: 1, bounce: 0)
        case .snappy: motion = MotionTuning(speed: 1.5, bounce: 0.15)
        case .playful: motion = MotionTuning(speed: 1.15, bounce: 1)
        case .quiet: motion = MotionTuning(speed: 1.15, bounce: 0)
        }
        for area in FeelArea.allCases { self[area] = motion }
        soundStyle = preset == .calm || preset == .quiet ? .soft : preset == .playful ? .bright : .classic
        volume = preset == .quiet ? 0.25 : preset == .calm ? 0.5 : preset == .original ? 1 : 0.75
        hoverSound = preset != .quiet
        gentleHaptics = preset == .calm || preset == .quiet
    }

    var matchingPreset: FeelPreset? {
        FeelPreset.allCases.first { preset in
            var copy = self
            copy.apply(preset)
            return copy == self
        }
    }
}

enum FeelPreset: String, CaseIterable {
    case original, calm, snappy, playful, quiet
    var title: String {
        switch self {
        case .original: L("Original")
        case .calm: L("Calm")
        case .snappy: L("Snappy")
        case .playful: L("Playful")
        case .quiet: L("Quiet")
        }
    }
}

/// Scale native text in place, retaining each control's original font so repeated updates never compound.
/// Custom-drawn menus use `font` directly. Annotation/export fonts deliberately don't use this helper.
@MainActor
enum AppTypography {
    private final class Record: NSObject {
        let original: NSFont
        var applied: NSFont
        init(_ font: NSFont) { original = font; applied = font }
    }
    private static let records = NSMapTable<NSView, Record>.weakToStrongObjects()
    private static var observers: [NSObjectProtocol] = []

    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * Prefs.interaction.textSize.scale,
                    weight: Prefs.interaction.boldText ? max(weight, .semibold) : weight)
    }

    static func install() {
        guard observers.isEmpty else { return }
        for name in [Prefs.changed, NSWindow.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for window in NSApp.windows where !(window is NSOpenPanel) && !(window is NSSavePanel) && !(window is NSColorPanel) && !(window is NSFontPanel) {
                        if let content = window.contentView {
                            apply(to: content)
                            if name == Prefs.changed { redraw(content) }
                        }
                    }
                }
            })
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        for child in view.subviews { redraw(child) }
    }

    static func apply(to view: NSView) {
        if let text = view as? NSTextView, text.isFieldEditor { return }
        let current = (view as? NSControl)?.font ?? (view as? NSTextView)?.font
        if let current {
            var record = records.object(forKey: view)
            if record == nil || record?.applied != current {
                record = Record(current)
                records.setObject(record, forKey: view)
            }
            if let record {
                var font = NSFont(descriptor: record.original.fontDescriptor,
                                  size: record.original.pointSize * Prefs.interaction.textSize.scale) ?? record.original
                if Prefs.interaction.boldText { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                record.applied = font
                if current != font {
                    if let control = view as? NSControl { control.font = font }
                    if let text = view as? NSTextView { text.font = font }
                    view.invalidateIntrinsicContentSize()
                }
            }
        }
        for child in view.subviews { apply(to: child) }
    }
}
