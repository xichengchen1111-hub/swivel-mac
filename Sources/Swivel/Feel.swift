import AppKit
import QuartzCore
import AudioToolbox
import IOKit

/// A damped spring that can be retargeted at any moment without a jump (position and velocity carry over).
///
/// Parameterised like SwiftUI: `response` is the period of the undamped oscillation in seconds, `damping` is the
/// damping fraction (1 = no overshoot, lower = bouncier). It is solved analytically, so any frame length is stable.
struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var response: CGFloat
    var damping: CGFloat

    init(_ value: CGFloat = 0, response: CGFloat = 0.3, damping: CGFloat = 0.8) {
        self.value = value
        self.target = value
        self.response = response
        self.damping = damping
    }

    var isSettled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.005 }

    /// Jumps to a value with no motion.
    mutating func snap(_ v: CGFloat) {
        value = v
        target = v
        velocity = 0
    }

    mutating func step(_ dt: CGFloat, tuning: MotionTuning = MotionTuning()) {
        guard dt > 0, !isSettled else {
            if isSettled { value = target; velocity = 0 }
            return
        }
        let w0 = 2 * .pi / max(response / tuning.safeSpeed, 0.001)
        let zeta = min(max(tuning.damping(damping), 0.05), 1)
        let x0 = value - target, v0 = velocity
        let x: CGFloat, v: CGFloat
        if zeta < 0.999 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * w0 * dt)
            let c = cos(wd * dt), s = sin(wd * dt)
            let b = (v0 + zeta * w0 * x0) / wd
            x = decay * (x0 * c + b * s)
            v = decay * ((b * wd - zeta * w0 * x0) * c - (x0 * wd + zeta * w0 * b) * s)
        } else {
            let decay = exp(-w0 * dt)
            let b = v0 + w0 * x0
            x = decay * (x0 + b * dt)
            v = decay * (b - w0 * (x0 + b * dt))
        }
        value = target + x
        velocity = v
    }
}

/// Calls `onFrame` with the frame time on every display refresh (120 Hz on ProMotion) until it returns false.
@MainActor
final class FrameDriver: NSObject {
    /// Return true to keep animating.
    var onFrame: ((CGFloat) -> Bool)?
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    /// Host time of the last tick (or of start). A link can stop firing for good — after sleep, a display change or
    /// its window being ordered out mid-animation — while still existing; without this check every later `start()`
    /// would be ignored and the view would stay frozen on its first frame (an invisible card or menu).
    private var lastTick: CFTimeInterval = 0
    static let stallLimit: CFTimeInterval = 0.25

    init(view: NSView) {
        self.view = view
    }

    var isRunning: Bool { link != nil && CACurrentMediaTime() - lastTick <= Self.stallLimit }

    func start() {
        if link != nil, CACurrentMediaTime() - lastTick > Self.stallLimit { stop() }
        guard link == nil, let view, view.window != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        last = 0
        lastTick = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Advance to the time this frame will be shown. The first frame and long stalls advance by one nominal
        // frame, so nothing jumps.
        let now = link.targetTimestamp
        let dt = last == 0 ? link.targetTimestamp - link.timestamp : min(max(now - last, 1.0 / 240), 1.0 / 30)
        last = now
        lastTick = CACurrentMediaTime()
        if onFrame?(CGFloat(dt)) != true { stop() }
    }
}

/// Shared rules for motion: honour Reduce Motion everywhere.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension CGFloat {
    /// Linear interpolation from self to `to` by t.
    func mix(_ to: CGFloat, _ t: CGFloat) -> CGFloat { self + (to - self) * t }
}

extension NSColor {
    /// Blends two colours in sRGB (NSColor.blended works in the receiver's space, which can be a pattern or catalog).
    func mix(_ other: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return t < 0.5 ? self : other }
        let t = Swift.min(Swift.max(t, 0), 1)
        return NSColor(srgbRed: a.redComponent.mix(b.redComponent, t), green: a.greenComponent.mix(b.greenComponent, t),
                       blue: a.blueComponent.mix(b.blueComponent, t), alpha: a.alphaComponent.mix(b.alphaComponent, t))
    }
}

/// The moments the app gives tactile and audible feedback for. Each channel has its own switch in Settings.
/// Every call fires its haptic and sound together, from the same event that changes the picture.
@MainActor
enum Feedback {
    /// The pointer moved onto a different menu item (or back onto the hub, where releasing cancels).
    static func hover(sound: Bool = true) {
        Haptics.tick(.alignment)
        if sound { Sounds.play(.hover) }
    }

    /// The menu turned to another page.
    static func page() {
        Haptics.tick(.levelChange)
        Sounds.play(.page)
    }

    /// A file was dropped on an item: the strongest tap, which must land even as the finger lifts.
    static func press() {
        Haptics.press()
        Sounds.play(.press)
    }

    /// A dropped action finished successfully.
    static func done() { Sounds.play(.done) }

    /// Nothing to do, or something failed.
    static func refuse() { Haptics.tick(.generic) }

    /// A feature switch was flipped: the click of a light switch, a little brighter for on than for off. No haptic:
    /// the click that flipped it already gave one.
    static func toggle(_ on: Bool) { Sounds.play(on ? .switchOn : .switchOff) }

    /// A drag started or a menu is opening: get the actuator and sounds ready so the first tap is on time.
    static func prepare() {
        Haptics.prepare()
        Sounds.prepare()
    }
}

/// Force Touch trackpad feedback.
///
/// Ticks go through NSHapticFeedbackManager, which respects the system setting and works from a background app
/// while a finger is on the trackpad (true during a drag). The drop press uses the trackpad actuator directly when
/// it's available, because the finger is often already lifting, which silences the public API.
@MainActor
enum Haptics {
    private static var last: CFTimeInterval = 0

    /// A light detent. Calls closer together than 40 ms are merged so fast sweeps don't buzz.
    static func tick(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Prefs.haptics else { return }
        let now = CACurrentMediaTime()
        guard now - last > (Prefs.interaction.gentleHaptics ? 0.08 : 0.04) else { return }
        last = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// A firm press; never merged away.
    static func press() {
        guard Prefs.haptics else { return }
        last = CACurrentMediaTime()
        if TrackpadActuator.isUsable {
            TrackpadActuator.actuate(Prefs.interaction.gentleHaptics ? 1 : 4)
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }

    static func prepare() {
        if Prefs.haptics, TrackpadActuator.isUsable { TrackpadActuator.prepare() }
    }
}

/// The trackpad's actuator, through the private MultitouchSupport framework. It is loaded at run time (never linked),
/// so a macOS without it just falls back to the public API. Actuation IDs come from the system's own table:
/// 1, 3, 5 are silent weak taps; 2, 4 medium with the click tone; 6 the strongest; 15, 16 the soft system detent.
enum TrackpadActuator {
    private struct API {
        let create: @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
        let open: @convention(c) (CFTypeRef) -> Int32
        let close: @convention(c) (CFTypeRef) -> Int32
        let actuate: @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32
    }

    private static let api: API? = {
        // `defaults write local.swivel.app privateHaptics -bool NO` turns this off if a macOS update misbehaves.
        if UserDefaults.standard.object(forKey: "privateHaptics") as? Bool == false { return nil }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let create = dlsym(handle, "MTActuatorCreateFromDeviceID"), let open = dlsym(handle, "MTActuatorOpen"),
              let close = dlsym(handle, "MTActuatorClose"), let actuate = dlsym(handle, "MTActuatorActuate") else { return nil }
        return API(create: unsafeBitCast(create, to: (@convention(c) (UInt64) -> Unmanaged<CFTypeRef>?).self),
                   open: unsafeBitCast(open, to: (@convention(c) (CFTypeRef) -> Int32).self),
                   close: unsafeBitCast(close, to: (@convention(c) (CFTypeRef) -> Int32).self),
                   actuate: unsafeBitCast(actuate, to: (@convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32).self))
    }()

    private static let queue = DispatchQueue(label: "local.swivel.haptics", qos: .userInteractive)
    private nonisolated(unsafe) static var open: [CFTypeRef] = []

    /// Available, and the user hasn't turned trackpad haptics off in System Settings (the actuator would ignore that).
    static var isUsable: Bool {
        guard api != nil else { return false }
        let detents = CFPreferencesCopyAppValue("ActuateDetents" as CFString, "com.apple.AppleMultitouchTrackpad" as CFString)
        return (detents as? NSNumber)?.intValue != 0
    }

    /// For diagnostics: trackpads that can actuate.
    static var deviceCount: Int { deviceIDs().count }

    /// Opens the actuators ahead of time; opening costs about 10 ms.
    static func prepare() {
        queue.async { _ = actuators() }
    }

    static func actuate(_ id: Int32) {
        queue.async {
            guard let api else { return }
            if fire(id, api) { return }
            // Handles go stale after sleep or a reconnect: close them all, reopen and try once more. If that fails
            // too, the public API still gives a tap while the finger is down.
            reset(api)
            if !fire(id, api) {
                DispatchQueue.main.async {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
        }
    }

    /// True if every open trackpad actuated (and there was at least one).
    private static func fire(_ id: Int32, _ api: API) -> Bool {
        let actuators = actuators()
        guard !actuators.isEmpty else { return false }
        return actuators.allSatisfy { api.actuate($0, id, 0, 0, 0) == 0 }
    }

    private static func reset(_ api: API) {
        for actuator in open { _ = api.close(actuator) }
        open = []
    }

    /// After the Mac wakes, reopen ahead of the next press rather than losing it to a stale handle.
    static func refreshAfterWake() {
        queue.async {
            guard let api, !open.isEmpty else { return }
            reset(api)
            _ = actuators()
        }
    }

    /// Every trackpad that can actuate (built-in and Magic Trackpad), opened once and kept.
    private static func actuators() -> [CFTypeRef] {
        guard open.isEmpty, let api else { return open }
        for id in deviceIDs() {
            guard let actuator = api.create(id)?.takeRetainedValue() else { continue }
            if api.open(actuator) == 0 { open.append(actuator) }
        }
        return open
    }

    private static func deviceIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: [UInt64] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("ActuationSupported") as? Bool) == true,
                  let id = (property("Multitouch ID") as? NSNumber)?.uint64Value else { continue }
            ids.append(id)
        }
        return ids
    }
}

/// Short interface sounds, synthesised once into the cache folder (no bundled audio) and played as system sounds:
/// they go to the user's sound-effects device, at the alert volume, and stay silent when “Play user interface sound
/// effects” is off.
@MainActor
enum Sounds {
    enum Effect: String, CaseIterable { case hover, page, press, done, switchOn, switchOff }

    private static var ids: [Effect: [SystemSoundID]] = [:]
    private static var loaded: SoundConfiguration?
    private static var lastHover: CFTimeInterval = 0
    private static var variant = 0
    private static var preparing = false
    private static var pending: (Effect, CFTimeInterval)?

    private static var configuration: SoundConfiguration {
        SoundConfiguration(style: Prefs.interaction.soundStyle, volume: Prefs.interaction.volume)
    }

    static func play(_ effect: Effect) {
        guard Prefs.soundEffects, configuration.volume > 0,
              effect != .hover || Prefs.interaction.hoverSound else { return }
        if effect == .hover {
            let now = CACurrentMediaTime()
            guard now - lastHover > 0.045 else { return }
            lastHover = now
        }
        guard loaded == configuration, let choices = ids[effect], !choices.isEmpty else {
            pending = (effect, CACurrentMediaTime())
            prepare()
            return
        }
        variant = (variant + 1 + Int.random(in: 0...1)) % choices.count
        AudioServicesPlaySystemSound(choices[effect == .hover ? variant : 0])
    }

    static var registeredCount: Int { ids.values.reduce(0) { $0 + $1.count } }

    /// Only the newest configuration may become active. Quieting or disabling sounds while a background
    /// synthesis is in progress must not replay a queued sound at the old volume.
    static func prepare() {
        let requested = configuration
        guard Prefs.soundEffects, requested.volume > 0, loaded != requested, !preparing else { return }
        preparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let made = SoundSynth.register(configuration: requested)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    preparing = false
                    guard Prefs.soundEffects, requested == configuration else {
                        for id in made.values.flatMap({ $0 }) { AudioServicesDisposeSystemSoundID(id) }
                        prepare()
                        return
                    }
                    for id in ids.values.flatMap({ $0 }) { AudioServicesDisposeSystemSoundID(id) }
                    ids = made
                    loaded = requested
                    let queued = pending
                    pending = nil
                    if let (effect, at) = queued, CACurrentMediaTime() - at < 0.4 { play(effect) }
                }
            }
        }
    }

}

/// Builds the interface sounds as 48 kHz 16-bit WAV files. Levels follow Apple's own UI sounds: a hover tick peaks
/// near −24 dBFS (it repeats), a press near −13 dBFS.
struct SoundConfiguration: Equatable, Sendable {
    let style: SoundStyle
    let level: Int
    var volume: Double { Double(level) / 100 }
    init(style: SoundStyle = .classic, volume: Double = 1) {
        self.style = style
        level = Int(((volume.isFinite ? min(max(volume, 0), 1) : 1) * 100).rounded())
    }
    var cacheKey: String { "\(style.rawValue)-\(level)" }
}

enum SoundSynth {
    static func register(configuration: SoundConfiguration = SoundConfiguration()) -> [Sounds.Effect: [SystemSoundID]] {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.swivel.app/sounds-v3/\(configuration.cacheKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [Sounds.Effect: [SystemSoundID]] = [:]
        for effect in Sounds.Effect.allCases {
            let variants: [(pitch: Double, gain: Double)] = effect == .hover
                ? [(1, 1), (0.97, 0.88), (1.03, 0.94)] : [(1, 1)]
            for (n, v) in variants.enumerated() {
                let url = folder.appendingPathComponent("\(effect.rawValue)-\(n).wav")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? wav(samples(effect, pitch: v.pitch, gain: v.gain, configuration: configuration)).write(to: url)
                }
                var id: SystemSoundID = 0
                if AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr { result[effect, default: []].append(id) }
            }
        }
        return result
    }

    private static let rate = 48_000.0

    static func samples(_ effect: Sounds.Effect, pitch: Double, gain: Double,
                        configuration: SoundConfiguration = SoundConfiguration()) -> [Float] {
        let pitch = pitch * configuration.style.pitch
        let gain = gain * configuration.volume * configuration.style.gain
        let length: Double, peak: Double
        switch effect {
        case .hover: (length, peak) = (0.025, 0.063)    // −24 dBFS
        case .page: (length, peak) = (0.07, 0.09)       // −21 dBFS
        case .press: (length, peak) = (0.11, 0.22)      // −13 dBFS
        case .done: (length, peak) = (0.26, 0.14)       // −17 dBFS
        case .switchOn, .switchOff: (length, peak) = (0.06, 0.16)   // −16 dBFS
        }
        let count = Int(rate * length)
        var noise = SystemRandomNumberGenerator()
        func hiss() -> Double { Double.random(in: -1...1, using: &noise) }
        func ping(_ t: Double, _ freq: Double, _ decay: Double) -> Double {
            t < 0 ? 0 : exp(-t / decay) * sin(2 * .pi * freq * pitch * t)
        }
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            switch effect {
            case .hover:
                // A small plastic detent: two bright partials and a breath of noise, gone in ~10 ms.
                out[i] = 0.6 * ping(t, 2350, 0.0038) + 0.3 * ping(t, 3900, 0.0022) + 0.15 * hiss() * exp(-t / 0.0007)
            case .page:
                // A ratchet: two detents, the second a little higher.
                out[i] = 0.6 * ping(t, 2000, 0.003) + 0.25 * ping(t, 3300, 0.0018)
                    + 0.65 * ping(t - 0.034, 2500, 0.003) + 0.25 * ping(t - 0.034, 4100, 0.0018)
            case .press:
                // A keycap bottoming out: a sharp click over a short, falling low body.
                let f = 210 - 80 * min(t / 0.05, 1)
                out[i] = 0.75 * exp(-t / 0.022) * sin(2 * .pi * f * pitch * t) + 0.3 * ping(t, 1150, 0.006)
                    + 0.3 * hiss() * exp(-t / 0.001)
            case .done:
                // A soft two-note chime (C6 then G6) with a quick attack.
                let attack = min(t / 0.004, 1)
                out[i] = attack * (0.55 * (ping(t, 1046.5, 0.07) + 0.25 * ping(t, 2093, 0.03))
                    + 0.6 * (ping(t - 0.075, 1568, 0.09) + 0.2 * ping(t - 0.075, 3136, 0.035)))
            case .switchOn, .switchOff:
                // A rocker light switch: the lever's soft first contact, then the snap 9 ms later, a sharp crack of
                // noise over two plastic resonances and a short low thump. "On" is a little higher and crisper.
                let up: Double = effect == .switchOn ? 1.12 : 0.88
                let snap = t - 0.009
                let crack = snap < 0 ? 0 : hiss() * exp(-snap / 0.0006)
                out[i] = 0.18 * ping(t, 2900 * up, 0.0015)
                    + 0.55 * crack + 0.5 * ping(snap, 1750 * up, 0.004) + 0.3 * ping(snap, 3400 * up, 0.0025)
                    + 0.45 * ping(snap, 150 * up, 0.012)
            }
            // Fade the last few milliseconds so nothing clicks at the cut.
            out[i] *= min(Double(count - i) / (rate * 0.004), 1)
        }
        let loudest = out.map(abs).max() ?? 1
        return out.map { Float($0 / max(loudest, 1e-9) * peak * gain) }
    }

    /// A minimal mono 16-bit PCM WAV file.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * 32_767)) }
        return data
    }
}
