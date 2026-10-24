import AppKit
import AVFoundation
import AVKit
import os

/// Edits a video (or an audio file) with a player to preview it, in sections: Trim (two handles), Picture (crop to a
/// ratio, turn, flip), Speed, Sound (volume, removing it, fades) and Color (looks and four sliders). Audio files get
/// Trim, Speed and Sound.
///
/// The trim handles stop with a tap at the clip's ends (reaching exactly 0 and the full length) and where they meet;
/// scrubbing shows the frame under the handle (a nearby one while dragging, the exact one on release), and playback
/// stays inside the cut. Every other control changes the preview in place: the player draws each frame through
/// the current settings, plays at the chosen speed and mixes the sound with the chosen volume and fades.
final class TrimEditor: Editor {
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    /// Known once `load()` has read the asset.
    private(set) var duration = 0.0
    private(set) var isAudio: Bool
    private(set) var start: DetentSlider!
    private(set) var end: DetentSlider!
    private let startLabel = NSTextField(labelWithString: L(""))
    private let endLabel = NSTextField(labelWithString: L(""))
    private let lengthLabel = NSTextField(labelWithString: L(""))
    private var lastStart = 0.0
    private var lastEnd = 0.0
    /// The handles are pushed together at the minimum gap.
    private var pinned = false
    // Seeking chases the newest target with one seek in flight at a time (Apple QA1820), so scrubbing never queues up.
    private var seekTarget = 0.0
    /// Opening or Reset shows the first frame once; other controls never move the playhead.
    private var showsFirstFrame = true
    /// A trim handle (not a volume or colour slider) is being dragged, so letting go lands exactly on it.
    private var scrubbingHandle = false
    private var seekExact = true
    private var seeking = false
    private var rateObservation: NSKeyValueObservation?

    private var sections: [String] = []
    private var section: NSSegmentedControl!
    private var pages: [String: [NSView]] = [:]
    private var pageViews: [NSStackView] = []
    // Picture
    private var ratio: NSPopUpButton!
    private var position: DetentSlider!
    private var turns: NSSegmentedControl!
    private var flip: NSButton!
    private(set) var burnSubtitles: NSButton!
    private(set) var subtitleCues: [SubtitleCue] = []
    private let subtitleName = NSTextField(labelWithString: "")
    private let subtitleStatus = NSTextField(wrappingLabelWithString: "")
    private let subtitleProgress = NSProgressIndicator()
    private var generateSubtitles: NSButton?
    private var subtitleLanguage: NSPopUpButton?
    private var generating: Task<Void, Never>?
    // Speed
    private var speed: NSSegmentedControl!
    // Sound
    private var volume: DetentSlider!
    private let volumeLabel = TrimEditor.valueLabel()
    private var removeAudio: NSButton!
    private var reduceNoise: NSButton!
    private var noiseStrength: DetentSlider!
    private var exportTask: Task<[URL], Error>?
    private var musicURL: URL?
    private var musicVolume: DetentSlider!
    private var duckMusic: NSButton!
    private var duckDB: DetentSlider!
    private let musicName = NSTextField(labelWithString: "")
    private let duckLabel = TrimEditor.valueLabel()
    private let musicStatus = NSTextField(wrappingLabelWithString: "")
    private lazy var musicPreview: MusicPreview = {
        let preview = MusicPreview(master: player, view: playerView, source: source)
        preview.onStatus = { [weak self] text in self?.musicStatus.stringValue = text }
        return preview
    }()
    private var fadeIn: DetentSlider!
    private var fadeOut: DetentSlider!
    private let fadeInLabel = TrimEditor.valueLabel()
    private let fadeOutLabel = TrimEditor.valueLabel()
    // Color
    private let strip = LookStrip(looks: PhotoLook.all)
    private var strength: DetentSlider!
    private let strengthLabel = TrimEditor.valueLabel()
    private var look = 0
    private var colorSliders: [(slider: DetentSlider, label: NSTextField, key: WritableKeyPath<PhotoSettings, Double>)] = []

    /// What every frame of the preview is drawn with; the composition reads it on its own thread.
    private let live = OSAllocatedUnfairLock(initialState: VideoSettings())
    private var videoComposition: AVMutableVideoComposition?
    private var audioTrack: AVAssetTrack?
    private var upright = CGSize.zero
    private var shownPicture: VideoSettings?

    /// Builds the window at once; the asset's length and tracks load in `load()`, after `present()` has counted the
    /// window, so the menu that opened it doesn't put up a busy toast meanwhile. (Still `async throws`, as callers
    /// await it.)
    init(source: URL) async throws {
        asset = Video.openAsset(source)
        isAudio = FileKind.of(source) == .audio
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        playerView.player = player
        playerView.controlsStyle = .inline
        super.init(title: isAudio ? "Trim Audio" : "Trim Video", source: source, canvas: playerView)
        if !isAudio { window.setContentSize(NSSize(width: 620, height: 780)) }

        // Each handle's default is its own end of the clip: an end stop that taps, never a band that swallows the
        // first or last seconds. The real range arrives with the duration.
        start = slider(0, 1, 0)
        end = slider(0, 1, 1)
        for label in [startLabel, endLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        lengthLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        lengthLabel.textColor = .controlAccentColor
        pages["Trim"] = [makeRow("Start", [start, startLabel]), makeRow("End", [end, endLabel]), makeRow("Length", [lengthLabel])]

        ratio = popup(VideoEdit.ratios.map(\.name))
        position = slider(0, 1, 0.5)
        turns = segments(["0°", "90°", "180°", "270°"])
        flip = checkbox("Flip", false)
        pages["Picture"] = [makeRow("Aspect ratio", [ratio]), makeRow("Position", [position]),
                            makeRow("Rotate", [turns, flip])]

        speed = segments(VideoEdit.speeds.map { Self.speedName($0) })
        speed.selectedSegment = VideoEdit.speeds.firstIndex(of: 1) ?? 0
        let pitch = NSTextField(labelWithString: L("Sound keeps its pitch."))
        pitch.textColor = .secondaryLabelColor
        pitch.font = .systemFont(ofSize: 11)
        pages["Speed"] = [makeRow("Speed", [speed]), makeRow("", [pitch])]

        volume = slider(0, 1, 1)
        removeAudio = checkbox("Remove audio", false)
        fadeIn = slider(0, 3, 0)
        fadeOut = slider(0, 3, 0)
        var sound = [makeRow("Volume", [volume, volumeLabel])]
        if !isAudio { sound.append(makeRow("", [removeAudio])) }
        sound += [makeRow("Fade in", [fadeIn, fadeInLabel]), makeRow("Fade out", [fadeOut, fadeOutLabel])]
        reduceNoise = checkbox("Reduce Noise", false)
        noiseStrength = slider(0, 1, 0.75)
        sound.append(makeRow("", [reduceNoise, noiseStrength]))
        musicVolume = slider(0, 1, 0.4)
        duckMusic = checkbox("Lower music when someone speaks", true)
        duckDB = slider(-30, 0, -12)
        musicName.lineBreakMode = .byTruncatingMiddle
        musicName.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        musicStatus.font = .systemFont(ofSize: 10); musicStatus.textColor = .secondaryLabelColor
        if !isAudio {
            let chooseMusic = NSButton(title: L("Choose Music…"), target: self, action: #selector(chooseMusicClicked))
            let clearMusic = NSButton(title: L("Remove Music"), target: self, action: #selector(removeMusicClicked))
            for button in [chooseMusic, clearMusic] { button.bezelStyle = .push }
            sound += [makeRow("Music", [chooseMusic, clearMusic, musicName]), makeRow("Music Volume", [musicVolume]),
                      makeRow("", [duckMusic]), makeRow("Duck by", [duckDB, duckLabel]), makeRow("", [musicStatus])]
            window.setContentSize(NSSize(width: 680, height: 860))
        }
        pages["Sound"] = sound

        strip.onPick = { [weak self] index in
            guard let self, self.isLoaded, !self.isSaving, index != self.look else { return }
            self.look = index
            self.update()
        }
        strength = slider(0, 1, 1)
        var color: [NSView] = [strip, makeRow("Strength", [strength, strengthLabel])]
        for name in VideoEdit.colorFields {
            guard let field = PhotoSettings.fields.first(where: { $0.name == name }) else { continue }
            let control = slider(field.range.lowerBound, field.range.upperBound, 0)
            let label = Self.valueLabel()
            colorSliders.append((control, label, field.key))
            color.append(makeRow(name, [control, label]))
        }
        pages["Color"] = color

        // Where subtitles come from first (speech on this Mac, or an SRT file), then whether to draw them in.
        let explanation = NSTextField(wrappingLabelWithString: L("Make subtitles from the video's speech on this Mac, or use an SRT subtitle file. Embedded subtitles are drawn into the picture, so they show in every player."))
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 500
        var subtitles: [NSView] = [makeRow("", [explanation])]
        if #available(macOS 26, *) {
            let generate = NSButton(title: L("Generate from Speech"), target: self, action: #selector(generateSubtitlesClicked))
            generate.bezelStyle = .push
            let language = popup(Prefs.transcriptionLanguageTitles)
            language.selectItem(at: Prefs.transcriptionLanguages.firstIndex(of: Prefs.transcriptionLanguage) ?? 0)
            generateSubtitles = generate; subtitleLanguage = language
            subtitles.append(makeRow("", [generate, language]))
        }
        let chooseSubtitles = NSButton(title: L("Choose Subtitle File (.srt)…"), target: self, action: #selector(chooseSubtitlesClicked))
        chooseSubtitles.bezelStyle = .push
        subtitleName.lineBreakMode = .byTruncatingMiddle
        subtitleName.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        subtitleStatus.font = .systemFont(ofSize: 11); subtitleStatus.textColor = .secondaryLabelColor
        subtitleStatus.preferredMaxLayoutWidth = 500
        subtitleProgress.style = .bar; subtitleProgress.minValue = 0; subtitleProgress.maxValue = 1
        subtitleProgress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        subtitleProgress.isHidden = true
        burnSubtitles = checkbox("Embed subtitles in the video (hard subtitles)", false)
        subtitles += [makeRow("", [chooseSubtitles, subtitleName]), makeRow("", [subtitleProgress, subtitleStatus]),
                      makeRow("", [burnSubtitles])]
        pages["Subtitles"] = subtitles
        sections = isAudio ? ["Trim", "Speed", "Sound"] : ["Trim", "Picture", "Speed", "Sound", "Color", "Subtitles"]
        section = segments(sections)
        controls.addArrangedSubview(section)
        // Every section is laid over the others in one box as tall as the tallest, so switching sections never
        // resizes the player above.
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        let fit = box.heightAnchor.constraint(equalToConstant: 0)
        fit.priority = .defaultLow
        fit.isActive = true
        for name in sections {
            let rows = pages[name] ?? []
            let page = NSStackView(views: rows)
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 10
            page.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                page.topAnchor.constraint(equalTo: box.topAnchor),
                box.bottomAnchor.constraint(greaterThanOrEqualTo: page.bottomAnchor),
            ])
            for row in rows { row.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
            pageViews.append(page)
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.playbackChanged() }
        }
    }

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return label
    }

    private static func speedName(_ speed: Double) -> String {
        (speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)) + "×"
    }

    override func load() async throws {
        let seconds = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = video == nil
        guard seconds > 0 else { throw ToolError("This file has no duration") }  // also NaN (indefinite)
        duration = seconds
        if audio != isAudio {
            isAudio = audio
            window.title = L(audio ? "Trim Audio" : "Trim Video")
        }
        for handle in [start!, end!] { handle.maxValue = seconds }
        start.doubleValue = 0
        end.doubleValue = seconds
        end.neutral = seconds
        lastStart = 0
        lastEnd = seconds
        audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        if audioTrack == nil { removeAudio.isEnabled = false }
        if !isAudio { loadSiblingSubtitles() }
        let initial = settings
        live.withLock { $0 = initial }
        guard let video else { return }
        upright = try await VideoEdit.uprightSize(of: video)
        let composition = try await VideoEdit.videoComposition(for: asset, settings: live, preview: true, upright: upright)
        videoComposition = composition
        player.currentItem?.videoComposition = composition
        shownPicture = settings
        // The looks strip shows each look on the first frame.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        if let first = try? await generator.image(at: .zero).image {
            let thumbs = try await Images.detached { PhotoLook.all.map { PhotoAdjust.render(first, $0.settings) } }
            strip.setThumbnails(thumbs)
        }
    }

    /// The controls as one value.
    private var settings: VideoSettings {
        var s = VideoSettings()
        s.start = start.doubleValue
        s.end = end.doubleValue
        s.speed = VideoEdit.speeds[max(0, speed.selectedSegment)]
        if !isAudio {
            s.quarterTurns = max(0, turns.selectedSegment)
            s.flip = flip.state == .on
            s.ratio = VideoEdit.ratios[max(0, ratio.indexOfSelectedItem)].value
            s.position = position.doubleValue
            s.subtitles = burnSubtitles.state == .on ? subtitleCues : []
            s.musicURL = musicURL
            s.musicVolume = musicVolume.doubleValue
            s.duckMusic = duckMusic.state == .on
            s.duckDB = duckDB.doubleValue
            s.removeAudio = removeAudio.state == .on && removeAudio.isEnabled
            var color = PhotoSettings()
            for control in colorSliders { color[keyPath: control.key] = control.slider.doubleValue }
            s.color = color.adding(PhotoLook.all[look].settings, amount: strength.doubleValue)
        }
        s.noiseReduction = reduceNoise.state == .on ? noiseStrength.doubleValue : 0
        s.volume = volume.doubleValue
        s.fadeIn = fadeIn.doubleValue
        s.fadeOut = fadeOut.doubleValue
        return s
    }

    private func time(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
    }

    override func update() {
        for (index, page) in pageViews.enumerated() { page.isHidden = index != section.selectedSegment }
        // Keep at least a tenth of a second between the handles, and preview whichever one moved.
        let startMoved = start.doubleValue != lastStart, endMoved = end.doubleValue != lastEnd
        var meeting = false
        if end.doubleValue < start.doubleValue + 0.1 {
            if startMoved { start.doubleValue = max(0, end.doubleValue - 0.1) } else { end.doubleValue = min(duration, start.doubleValue + 0.1) }
            meeting = true
        }
        // The handles meeting is a hard stop: one tap as they touch, none while held there.
        if meeting, !pinned, isTracking { Haptics.tick(.alignment) }
        pinned = meeting
        let firstShow = showsFirstFrame && isLoaded
        if firstShow { showsFirstFrame = false }
        if (startMoved || endMoved) && isTracking { scrubbingHandle = true }
        lastStart = start.doubleValue
        lastEnd = end.doubleValue

        let s = settings
        startLabel.stringValue = time(s.start)
        endLabel.stringValue = time(s.end)
        lengthLabel.stringValue = time(s.outputLength)
        position.isEnabled = s.ratio != nil && !isSaving
        volume.isEnabled = !s.removeAudio && audioTrack != nil && !isSaving
        reduceNoise.isEnabled = !s.removeAudio && audioTrack != nil && !isSaving
        noiseStrength.isEnabled = reduceNoise.state == .on && reduceNoise.isEnabled
        musicVolume.isEnabled = musicURL != nil && !isSaving
        duckMusic.isEnabled = musicURL != nil && audioTrack != nil && !s.removeAudio && !isSaving
        duckDB.isEnabled = duckMusic.isEnabled && s.duckMusic
        duckLabel.stringValue = String(format: "%.0f dB", s.duckDB)
        musicPreview.update(s)
        if subtitleCues.isEmpty { burnSubtitles.state = .off }
        burnSubtitles.isEnabled = !subtitleCues.isEmpty && generating == nil && !isSaving
        generateSubtitles?.isEnabled = audioTrack != nil && generating == nil && !isSaving
        volumeLabel.stringValue = "\(Int((s.volume * 100).rounded()))%"
        fadeInLabel.stringValue = String(format: "%.1f s", s.fadeIn)
        fadeOutLabel.stringValue = String(format: "%.1f s", s.fadeOut)
        for (label, value) in [(volumeLabel, s.volume == 1), (fadeInLabel, s.fadeIn == 0), (fadeOutLabel, s.fadeOut == 0)] {
            label.textColor = value ? .tertiaryLabelColor : .secondaryLabelColor
        }
        strip.selected = look
        strength.isEnabled = look != 0 && !isSaving
        strengthLabel.stringValue = "\(Int((strength.doubleValue * 100).rounded()))%"
        strengthLabel.textColor = look == 0 ? .tertiaryLabelColor : .secondaryLabelColor
        for control in colorSliders {
            let value = control.slider.doubleValue
            control.label.stringValue = value == 0 ? "0" : (value > 0 ? "+" : "−") + "\(Int(abs(value * 100).rounded()))"
            control.label.textColor = value == 0 ? .tertiaryLabelColor : .secondaryLabelColor
        }

        // The preview: the cut, the speed, the sound and the picture, each changed in place.
        live.withLock { [s] in $0 = s }
        player.currentItem?.reversePlaybackEndTime = CMTime(seconds: s.start, preferredTimescale: 600)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: s.end, preferredTimescale: 600)
        player.defaultRate = Float(s.speed)
        if player.rate > 0, player.rate != Float(s.speed) { player.rate = Float(s.speed) }
        if let audioTrack { player.currentItem?.audioMix = VideoEdit.audioMix(for: audioTrack, s, preview: true) }
        if let videoComposition, shownPicture != s {
            // A new size needs a new render size; any change needs the paused frame drawn again, which handing the
            // item its composition again does.
            videoComposition.renderSize = VideoEdit.renderSize(upright: upright, s)
            player.currentItem?.videoComposition = videoComposition.copy() as? AVVideoComposition
            shownPicture = s
        }
        // Opening (or Reset) shows the first frame of the cut, not its last.
        if startMoved || endMoved || firstShow {
            seek(to: endMoved && !startMoved ? s.end : s.start, exact: !isTracking)
        }
    }

    @objc private func chooseMusicClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.musicURL = url; self.musicName.stringValue = url.lastPathComponent; self.update()
        }
    }
    @objc private func removeMusicClicked() { musicURL = nil; musicName.stringValue = ""; update() }

    @objc private func chooseSubtitlesClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                self.subtitleCues = try Subtitles.read(url)
                guard !self.subtitleCues.isEmpty else { throw ToolError(L("No subtitles were found in this file.")) }
                self.subtitleName.stringValue = url.lastPathComponent
                self.subtitleStatus.stringValue = L("%d subtitles ready.", self.subtitleCues.count)
                self.burnSubtitles.state = .on
                self.update()
            } catch { NSAlert(error: error).beginSheetModal(for: self.window) }
        }
    }

    /// The Subtitles action saves "clip.srt" beside "clip.mp4"; pick it up so it's one tick away. Not ticked: a plain
    /// trim shouldn't gain captions just because a file sits next to the video.
    private func loadSiblingSubtitles() {
        let srt = source.deletingPathExtension().appendingPathExtension("srt")
        guard let cues = try? Subtitles.read(srt), !cues.isEmpty else { return }
        subtitleCues = cues
        subtitleName.stringValue = srt.lastPathComponent
        subtitleStatus.stringValue = L("Found %@ next to the video.", srt.lastPathComponent)
    }

    @available(macOS 26, *)
    @objc private func generateSubtitlesClicked() {
        guard generating == nil, isLoaded, !isSaving else { return }
        if let subtitleLanguage {
            Prefs.transcriptionLanguage = Prefs.transcriptionLanguages[max(0, subtitleLanguage.indexOfSelectedItem)]
        }
        let source = self.source
        subtitleProgress.isHidden = false
        generating = Task { [weak self] in
            guard let self else { return }
            do {
                let locale = try await SpeechResources.prepare(Prefs.transcriptionLocale, window: window) { [weak self] value in
                    self?.subtitleStatus.stringValue = L("Downloading language resources…")
                    self?.subtitleProgress.isIndeterminate = false
                    self?.subtitleProgress.doubleValue = value
                }
                subtitleStatus.stringValue = L("Recognizing speech on this Mac…")
                subtitleProgress.isIndeterminate = true; subtitleProgress.startAnimation(nil)
                let words = try await LocalTranscription.recognize(source, locale: locale)
                try Task.checkCancellation()
                guard !words.isEmpty else { throw ToolError(L("No speech was found.")) }
                subtitleCues = Subtitles.cues(words)
                subtitleName.stringValue = L("Generated from speech")
                subtitleStatus.stringValue = L("%d subtitles ready.", subtitleCues.count)
                burnSubtitles.state = .on
            } catch is CancellationError {
                subtitleStatus.stringValue = ""
            } catch is Cancelled {
                subtitleStatus.stringValue = ""
            } catch {
                subtitleStatus.stringValue = ""
                if !Task.isCancelled { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
            subtitleProgress.stopAnimation(nil); subtitleProgress.isHidden = true
            generating = nil
            update()
        }
        update()
    }

    override func trackingEnded() {
        guard scrubbingHandle else { return }
        scrubbingHandle = false
        seek(to: seekTarget, exact: true)
    }

    private func seek(to seconds: Double, exact: Bool) {
        seekTarget = seconds
        seekExact = exact
        if !seeking { chase() }
    }

    private func chase() {
        seeking = true
        let target = seekTarget, exact = seekExact
        // While dragging any nearby frame will do (quick to decode); the frame left on screen is exact.
        let slack = exact ? CMTime.zero : CMTime(seconds: min(duration / 200, 0.25), preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: slack, toleranceAfter: slack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if self.seekTarget != target || (self.seekExact && !exact) { self.chase() }
            }
        }
    }

    /// Play starts from the beginning of the cut when the playhead is outside it (or sitting at its end).
    private func playbackChanged() {
        musicPreview.playbackChanged()
        guard player.rate > 0, isLoaded else { return }
        let now = player.currentTime().seconds
        if now < start.doubleValue - 0.05 || now >= end.doubleValue - 0.05 {
            player.seek(to: CMTime(seconds: start.doubleValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    override func reset() {
        showsFirstFrame = true
        start.doubleValue = 0
        end.doubleValue = duration
        ratio.selectItem(at: 0)
        position.doubleValue = 0.5
        turns.selectedSegment = 0
        flip.state = .off
        speed.selectedSegment = VideoEdit.speeds.firstIndex(of: 1) ?? 0
        volume.doubleValue = 1
        musicURL = nil; musicName.stringValue = ""; musicVolume.doubleValue = 0.4; duckMusic.state = .on; duckDB.doubleValue = -12
        removeAudio.state = .off
        reduceNoise.state = .off
        noiseStrength.doubleValue = 0.75
        burnSubtitles.state = .off
        fadeIn.doubleValue = 0
        fadeOut.doubleValue = 0
        look = 0
        strength.doubleValue = 1
        for control in colorSliders { control.slider.doubleValue = 0 }
    }

    override var canCancelSaving: Bool { true }
    override func cancelSaving() { exportTask?.cancel() }
    override func didClose() {
        exportTask?.cancel()
        generating?.cancel()
        musicPreview.stop()
        rateObservation?.invalidate()
        rateObservation = nil
        player.pause()
    }

    override func apply() async throws -> [URL] {
        guard generating == nil else { throw ToolError(L("Subtitles are still being generated.")) }
        player.pause()
        musicPreview.playbackChanged()
        let source = self.source, settings = self.settings, audio = isAudio
        let task = Task { [try await VideoEdit.export(source, settings, isAudio: audio)] }
        exportTask = task
        defer { exportTask = nil }
        return try await task.value
    }
}

extension Video {
    /// Media that refers to other files (QuickTime reference movies, external data references) is never followed:
    /// converting a crafted movie could otherwise copy another local file's audio or video into the result.
    static func openAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    /// `openAsset`, plus a check that every track's media is inside the file itself.
    static func safeAsset(_ url: URL) async throws -> AVURLAsset {
        let asset = openAsset(url)
        for track in try await asset.load(.tracks) where try await !track.load(.isSelfContained) {
            throw ToolError(L("This movie uses media from other files. Only self-contained files can be converted."))
        }
        return asset
    }

    /// Joins videos (or audio files) end to end in the order they were selected.
    static func merge(_ urls: [URL], audioOnly: Bool) async throws -> URL {
        let composition = AVMutableComposition()
        let videoTrack = audioOnly ? nil : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        var audioTrack: AVMutableCompositionTrack?  // created on first use; an empty track makes export fail
        var cursor = CMTime.zero
        for url in urls {
            let asset = try await safeAsset(url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let videoTrack, let source = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                if cursor == .zero { videoTrack.preferredTransform = try await source.load(.preferredTransform) }
            }
            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = cursor + duration
        }
        let name = audioOnly ? "Merged.m4a" : "Merged.mp4"
        let preset = audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw ToolError("Can't merge these files") }
        return try await Paths.produce(urls[0].deletingLastPathComponent().appendingPathComponent(name)) {
            try await session.export(to: $0, as: audioOnly ? .m4a : .mp4)
        }
    }
}
