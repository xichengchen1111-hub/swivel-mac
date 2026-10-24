import AppKit

/// A modifier key that can open a menu while dragging.
enum TriggerKey: String, CaseIterable {
    /// `off`: the menu opens by no key during a drag. There are five keys and six menus, so one at least has none
    /// (My Wheel until the user gives it a key).
    case shift, command, control, option, fn, off

    /// Empty for `off`, which no tap matches.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        case .fn: .function
        case .off: []
        }
    }

    var symbol: String {
        switch self {
        case .shift: L("⇧")
        case .command: L("⌘")
        case .control: L("⌃")
        case .option: L("⌥")
        case .fn: L("fn")
        case .off: "–"
        }
    }

    var title: String {
        switch self {
        case .shift: L("⇧ Shift")
        case .command: L("⌘ Command")
        case .control: L("⌃ Control")
        case .option: L("⌥ Option")
        case .fn: L("fn / 🌐")
        case .off: L("Not used")
        }
    }

    /// Whether tapping these keys opens a menu with this key.
    func isTapped(in pressed: NSEvent.ModifierFlags) -> Bool { self != .off && pressed.contains(flag) }
}

/// How the menu that pops up under the cursor is laid out.
enum MenuStyle: String, CaseIterable {
    case wheel, list, shelf, notes, clothesline

    var title: String {
        switch self {
        case .wheel: L("Wheel")
        case .list: L("List")
        case .shelf: L("Bookshelf")
        case .notes: L("Sticky Notes")
        case .clothesline: L("Clothesline")
        }
    }

    var blurb: String {
        switch self {
        case .wheel: L("A ring of keycaps around the cursor.")
        case .list: L("A tidy column, like a context menu.")
        case .shelf: L("Quiet book spines on a satin shelf.")
        case .notes: L("Soft paper cards arranged in a grid.")
        case .clothesline: L("Tags pegged on a rope, swaying gently.")
        }
    }
}

/// User settings, stored in UserDefaults. Posts `Prefs.changed` whenever anything is saved.
@MainActor
enum Prefs {
    static let changed = Notification.Name("SwivelPrefsChanged")
    private static let defaults = UserDefaults.standard

    static let compressTargets = [0, 100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
    static let videoCompressTargets = [0, 8_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000]
    static var compressTargetBytes: Int {
        get { let value = defaults.integer(forKey: "compress.targetBytes"); return compressTargets.contains(value) ? value : 0 }
        set { defaults.set(newValue, forKey: "compress.targetBytes"); post() }
    }
    static var videoCompressTarget: Int {
        get { let value = defaults.integer(forKey: "videoCompress.target"); return videoCompressTargets.contains(value) ? value : 0 }
        set { defaults.set(newValue, forKey: "videoCompress.target"); post() }
    }

    static let transcriptionLanguages = ["app", "zh-CN", "en-US", "ja-JP"]
    static let transcriptionLanguageTitles = ["Follow App Language", "简体中文", "English", "日本語"]
    static var transcriptionLanguage: String {
        get { let value = defaults.string(forKey: "speech.language") ?? "app"; return transcriptionLanguages.contains(value) ? value : "app" }
        set { defaults.set(transcriptionLanguages.contains(newValue) ? newValue : "app", forKey: "speech.language"); post() }
    }
    static var transcriptionLocale: Locale {
        if transcriptionLanguage != "app" { return Locale(identifier: transcriptionLanguage) }
        return Locale(identifier: Language.resolved == .ja ? "ja-JP" : [.zhHans, .zhHant].contains(Language.resolved) ? "zh-CN" : "en-US")
    }

    /// Resize…'s last answer: how it measured, the number, and whether smaller images could grow.
    static var resizeMode: String {
        get { defaults.string(forKey: "resize.mode") ?? "longEdge" }
        set { defaults.set(newValue, forKey: "resize.mode"); post() }
    }
    static var resizeValue: Int {
        get { defaults.integer(forKey: "resize.value") }
        set { defaults.set(newValue, forKey: "resize.value"); post() }
    }
    static var resizeEnlarge: Bool {
        get { defaults.bool(forKey: "resize.enlarge") }
        set { defaults.set(newValue, forKey: "resize.enlarge"); post() }
    }

    /// Keep Awake also keeps the display on (otherwise only the Mac itself stays awake).
    static var keepAwakeDisplay: Bool {
        get { defaults.object(forKey: "keepAwake.display") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepAwake.display"); post() }
    }

    /// Which language model Quick Actions may ask (the key itself is in the keychain).
    static var assistant: Assistant.Settings {
        get { defaults.data(forKey: "assistant.v1").flatMap { try? JSONDecoder().decode(Assistant.Settings.self, from: $0) } ?? .standard }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "assistant.v1"); post() }
    }

    /// Folder styles applied lately, newest first (Change Style's Recent row).
    static var folderStyleRecents: [FolderStyle] {
        get { defaults.data(forKey: "folderStyle.recents.v1").flatMap { try? JSONDecoder().decode([FolderStyle].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "folderStyle.recents.v1"); post() }
    }

    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }

    private static var interactionCache: InteractionSettings = {
        guard let data = defaults.data(forKey: "interaction.v1"),
              let value = try? JSONDecoder().decode(InteractionSettings.self, from: data) else { return InteractionSettings() }
        return value.sanitized
    }()

    static var interaction: InteractionSettings {
        get { interactionCache }
        set {
            let value = newValue.sanitized
            guard value != interactionCache, let data = try? JSONEncoder().encode(value) else { return }
            interactionCache = value
            defaults.set(data, forKey: "interaction.v1")
            post()
        }
    }

    private static var clotheslineColorsCache: ClotheslineColors = {
        guard let data = defaults.data(forKey: "clothesline.colors.v1"),
              let value = try? JSONDecoder().decode(ClotheslineColors.self, from: data) else { return ClotheslineColors() }
        return value.sanitized
    }()

    static var clotheslineColors: ClotheslineColors {
        get { clotheslineColorsCache }
        set {
            let value = newValue.sanitized
            guard value != clotheslineColorsCache, let data = try? JSONEncoder().encode(value) else { return }
            clotheslineColorsCache = value
            defaults.set(data, forKey: "clothesline.colors.v1")
            post()
        }
    }

    private static var templateColorsCache: TemplateColors = {
        guard let data = defaults.data(forKey: "templates.colors.v1"),
              let value = try? JSONDecoder().decode(TemplateColors.self, from: data) else { return TemplateColors() }
        return value.sanitized
    }()

    static var templateColors: TemplateColors {
        get { templateColorsCache }
        set {
            let value = newValue.sanitized
            guard value != templateColorsCache, let data = try? JSONEncoder().encode(value) else { return }
            templateColorsCache = value
            defaults.set(data, forKey: "templates.colors.v1")
            post()
        }
    }

    /// Additional tools are opt-in. Disabling them retains their settings.
    static func featureEnabled(_ feature: Feature) -> Bool {
        defaults.bool(forKey: "feature.\(feature.rawValue)")
    }

    static func setFeatureEnabled(_ feature: Feature, _ enabled: Bool) {
        defaults.set(enabled, forKey: "feature.\(feature.rawValue)"); post()
    }

    static var imagePresets: [ImagePreset] {
        get {
            guard let data = defaults.data(forKey: "imagePresets.v1"),
                  let presets = try? JSONDecoder().decode([ImagePreset].self, from: data) else {
                return ImagePreset.starters
            }
            return presets.filter { $0.isValid }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue.filter { $0.isValid }) else { return }
            defaults.set(data, forKey: "imagePresets.v1"); post()
        }
    }

    static var quickShortcut: QuickShortcut {
        get { QuickShortcut(rawValue: defaults.string(forKey: "quickActions.shortcut") ?? "") ?? .space }
        set { defaults.set(newValue.rawValue, forKey: "quickActions.shortcut"); post() }
    }

    /// App Actions. Applications stay in "appTargets.v1" in the shape 1.6 reads (an older build that met a web page's
    /// delivery there failed on the whole list, fell back to the starters and saved those over it); web pages and the
    /// combined order have keys of their own, which older builds don't know about and leave alone.
    static let fileAppTargetKeys = ["appTargets.v1", "appTargets.pages.v1", "appTargets.order.v1"]
    static var fileAppTargets: [FileAppTarget] {
        get {
            let apps = defaults.data(forKey: fileAppTargetKeys[0]).flatMap(decodeEachTarget)
            let pages = defaults.data(forKey: fileAppTargetKeys[1]).flatMap(decodeEachTarget) ?? []
            guard apps != nil || !pages.isEmpty else { return FileAppTarget.starters }
            // 1.7.0 kept pages in the first list; they are read from either place.
            let order = defaults.stringArray(forKey: fileAppTargetKeys[2]) ?? []
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let values = ((apps ?? []) + pages).enumerated().sorted {
                (rank[$0.element.id] ?? order.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset)
            }.map(\.element)
            var ids = Set<String>()
            return values.filter { $0.isValid && ids.insert($0.id).inserted }
        }
        set {
            var ids = Set<String>()
            let values = newValue.filter { $0.isValid && ids.insert($0.id).inserted }
            guard let apps = try? JSONEncoder().encode(values.filter { !$0.isWebPage }),
                  let pages = try? JSONEncoder().encode(values.filter(\.isWebPage)) else { return }
            defaults.set(apps, forKey: fileAppTargetKeys[0])
            defaults.set(pages, forKey: fileAppTargetKeys[1])
            defaults.set(values.map(\.id), forKey: fileAppTargetKeys[2]); post()
        }
    }

    /// The targets in a saved list, one by one: an entry this build can't read is skipped instead of losing the rest.
    /// Nil only when the data isn't a list at all.
    static func decodeEachTarget(_ bytes: Data) -> [FileAppTarget]? {
        struct Entry: Decodable {
            let value: FileAppTarget?
            init(from decoder: Decoder) throws { value = try? FileAppTarget(from: decoder) }
        }
        return (try? JSONDecoder().decode([Entry].self, from: bytes))?.compactMap(\.value)
    }

    /// Force Touch trackpad taps when the pointer moves between menu items and on a drop.
    static var haptics: Bool {
        get { defaults.object(forKey: "feedback.haptics") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "feedback.haptics"); post() }
    }

    /// Short interface sounds for the same moments (always quiet, and off when macOS's UI sounds are off).
    static var soundEffects: Bool {
        get { defaults.object(forKey: "feedback.sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "feedback.sounds"); post() }
    }

    static var isEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); post() }
    }

    // MARK: Clothesline

    static var clotheslineEnabled: Bool {
        get { defaults.object(forKey: "clothesline.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clothesline.enabled"); post() }
    }

    /// Whether new screenshots go to the clothesline folder (asked once on first launch).
    static var clotheslineTakeover: Bool {
        get { defaults.bool(forKey: "clothesline.takeover") }
        set { defaults.set(newValue, forKey: "clothesline.takeover"); post() }
    }

    static var clotheslineAsked: Bool {
        get { defaults.bool(forKey: "clothesline.asked") }
        set { defaults.set(newValue, forKey: "clothesline.asked") }
    }

    static var clotheslineHangCopied: Bool {
        get { defaults.bool(forKey: "clothesline.hangCopied") }
        set { defaults.set(newValue, forKey: "clothesline.hangCopied"); post() }
    }

    static var style: MenuStyle {
        get { MenuStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .wheel }
        set { defaults.set(newValue.rawValue, forKey: "style"); post() }
    }

    private static let defaultKeys: [WheelMode: TriggerKey] = [.convert: .shift, .tools: .command, .actions: .control, .apps: .option, .codes: .fn]

    static func key(for mode: WheelMode) -> TriggerKey {
        // Preserve explicit old assignments first; give new wheels whichever keys remain free. Any number of menus
        // can be off; My Wheel has no default key, so it never takes one the user didn't give it.
        var chosen: [WheelMode: TriggerKey] = [:], used = Set<TriggerKey>()
        for candidate in WheelMode.allCases {
            if let value = defaults.string(forKey: "key.\(candidate.id)"), let key = TriggerKey(rawValue: value), key == .off || used.insert(key).inserted { chosen[candidate] = key }
        }
        for candidate in WheelMode.allCases where chosen[candidate] == nil {
            guard let preferred = defaultKeys[candidate] else { chosen[candidate] = .off; continue }
            let value = used.contains(preferred) ? TriggerKey.allCases.first { $0 != .off && !used.contains($0) } ?? .off : preferred
            chosen[candidate] = value; used.insert(value)
        }
        return chosen[mode]!
    }

    static var shortcutWheelEnabled: Bool {
        get { defaults.bool(forKey: "wheel.shortcutEnabled") }
        set { defaults.set(newValue, forKey: "wheel.shortcutEnabled"); post() }
    }
    static var wheelShortcut: WheelShortcut {
        get { WheelShortcut(rawValue: defaults.string(forKey: "wheel.shortcut") ?? "") ?? .j }
        set { defaults.set(newValue.rawValue, forKey: "wheel.shortcut"); post() }
    }

    /// Assigns a key; if another menu already used it, that menu takes this one's old key (possibly none).
    static func setKey(_ key: TriggerKey, for mode: WheelMode) {
        let old = self.key(for: mode)
        if key != .off, let clash = WheelMode.allCases.first(where: { $0 != mode && self.key(for: $0) == key }) {
            defaults.set(old.rawValue, forKey: "key.\(clash.id)")
        }
        defaults.set(key.rawValue, forKey: "key.\(mode.id)")
        post()
    }

    static func resetKeys() {
        for mode in WheelMode.allCases { defaults.removeObject(forKey: "key.\(mode.id)") }
        post()
    }

    // MARK: My Wheel

    /// My Wheel's actions in the user's order, as `CustomWheel.Ref` ids ("convert/JPG", "apps/app.<id>").
    static var customWheelItems: [String] {
        get { defaults.stringArray(forKey: "customWheel.items") ?? [] }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { CustomWheel.Ref(id: $0) != nil && seen.insert($0).inserted }, forKey: "customWheel.items"); post()
        }
    }

    /// The keyboard shortcut that opens My Wheel without a drag, if the user recorded one.
    static var customWheelShortcut: KeyCombo? {
        get {
            guard let bytes = defaults.data(forKey: "customWheel.shortcut"), let combo = try? JSONDecoder().decode(KeyCombo.self, from: bytes) else { return nil }
            return combo.isValid ? combo : nil
        }
        set {
            if let newValue, newValue.isValid, let bytes = try? JSONEncoder().encode(newValue) {
                defaults.set(bytes, forKey: "customWheel.shortcut")
            } else {
                defaults.removeObject(forKey: "customWheel.shortcut")
            }
            post()
        }
    }

    // MARK: Menu contents

    private static func slot(_ mode: WheelMode, _ kind: FileKind) -> String { "\(mode.id).\(kind.rawValue)" }

    static func hidden(_ mode: WheelMode, _ kind: FileKind) -> Set<String> {
        Set(defaults.stringArray(forKey: "hidden.\(slot(mode, kind))") ?? [])
    }

    static func setHidden(_ titles: Set<String>, _ mode: WheelMode, _ kind: FileKind) {
        defaults.set(Array(titles), forKey: "hidden.\(slot(mode, kind))")
        post()
    }

    static func order(_ mode: WheelMode, _ kind: FileKind) -> [String] {
        defaults.stringArray(forKey: "order.\(slot(mode, kind))") ?? []
    }

    static func setOrder(_ titles: [String], _ mode: WheelMode, _ kind: FileKind) {
        defaults.set(titles, forKey: "order.\(slot(mode, kind))")
        post()
    }

    /// Saves order and hidden items together, posting one change.
    static func setArrangement(order: [String], hidden: Set<String>, _ mode: WheelMode, _ kind: FileKind) {
        defaults.set(order, forKey: "order.\(slot(mode, kind))")
        defaults.set(Array(hidden), forKey: "hidden.\(slot(mode, kind))")
        post()
    }

    static func resetContents(_ mode: WheelMode, _ kind: FileKind) {
        defaults.removeObject(forKey: "hidden.\(slot(mode, kind))")
        defaults.removeObject(forKey: "order.\(slot(mode, kind))")
        post()
    }

    /// Applies the user's order and hidden set to a menu's default items.
    static func arrange(_ items: [WheelItem], _ mode: WheelMode, _ kind: FileKind) -> [WheelItem] {
        let hidden = self.hidden(mode, kind)
        let order = self.order(mode, kind)
        let visible = items.filter { !hidden.contains($0.title) }
        return visible.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.title) ?? (order.count + a.offset)
            let ib = order.firstIndex(of: b.element.title) ?? (order.count + b.offset)
            return ia < ib
        }.map(\.element)
    }
}
