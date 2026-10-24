import AVFoundation
import CoreImage
import os

/// Everything the video editor can change, in source seconds for the cut. Neutral is "the file as it is".
struct VideoSettings: Equatable, Sendable {
    var start = 0.0, end = 0.0
    var speed = 1.0
    /// Clockwise quarter turns on top of the file's own orientation.
    var quarterTurns = 0
    var flip = false
    /// Width ÷ height of the crop, or nil for the whole picture.
    var ratio: Double?
    /// Where the crop sits along the axis it cuts: 0 left/top, 1 right/bottom.
    var position = 0.5
    var volume = 1.0
    var removeAudio = false
    var noiseReduction = 0.0
    var musicURL: URL?
    var musicVolume = 0.4
    var duckMusic = true
    var duckDB = -12.0
    /// Seconds of the result, picture and sound together.
    var fadeIn = 0.0, fadeOut = 0.0
    var color = PhotoSettings()
    var subtitles: [SubtitleCue] = []

    /// How long the result plays.
    var outputLength: Double { max(0, end - start) / speed }
    var changesGeometry: Bool { quarterTurns % 4 != 0 || flip || ratio != nil }
    /// Only the cut differs from the file (the output is then called "trimmed").
    var isTrimOnly: Bool {
        musicURL == nil && noiseReduction == 0 && subtitles.isEmpty && speed == 1 && !changesGeometry && color.isNeutral && fadeIn == 0 && fadeOut == 0 && volume == 1 && !removeAudio
    }
}

enum VideoEdit {
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 4]
    static let ratios: [(name: String, value: Double?)] = [("Original", nil), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
                                                           ("1:1", 1), ("4:5", 0.8), ("4:3", 4.0 / 3)]
    /// The colour controls the video editor shows (the rest of Edit Photo's would be slow on every frame).
    static let colorFields = ["Exposure", "Contrast", "Saturation", "Warmth"]

    // MARK: Geometry (pure)

    static func turnedSize(_ size: CGSize, quarterTurns: Int) -> CGSize {
        quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The crop inside a picture of `size`: the largest `ratio` rectangle, slid by `position`, in Core Image's
    /// bottom-up coordinates. Whole even pixels, as H.264 and HEVC want.
    static func cropRect(in size: CGSize, ratio: Double?, position: Double) -> CGRect {
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        let w = even(size.width), h = even(size.height)
        guard let ratio, ratio > 0 else { return CGRect(x: 0, y: 0, width: w, height: h) }
        let p = min(max(position, 0), 1)
        if w / h > ratio {
            let cw = even(h * ratio)
            return CGRect(x: ((w - cw) * p).rounded(), y: 0, width: cw, height: h)
        }
        let ch = even(w / ratio)
        // Position 0 is the top, which is the high end of a bottom-up axis.
        return CGRect(x: 0, y: ((h - ch) * (1 - p)).rounded(), width: w, height: ch)
    }

    /// The picture's brightness (and the sound's share of its volume) at `time` seconds into a result `length`
    /// long: 0 → 1 over the fade in, 1 → 0 over the fade out.
    static func fade(at time: Double, length: Double, fadeIn: Double, fadeOut: Double) -> Double {
        var level = 1.0
        if fadeIn > 0 { level = min(level, max(0, time / fadeIn)) }
        if fadeOut > 0 { level = min(level, max(0, (length - time) / fadeOut)) }
        return min(level, 1)
    }

    /// One upright frame through flip, turns, crop, colour and fade; the result starts at the origin.
    static func frame(_ source: CIImage, _ s: VideoSettings, outputTime: Double) -> CIImage {
        var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        var size = image.extent.size
        if s.flip { image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
        for _ in 0..<((s.quarterTurns % 4 + 4) % 4) {
            // A clockwise quarter turn in bottom-up coordinates: (x, y) → (y, width − x).
            image = image.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width))
            size = CGSize(width: size.height, height: size.width)
        }
        let crop = cropRect(in: size, ratio: s.ratio, position: s.position)
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if !s.color.isNeutral { image = PhotoAdjust.apply(s.color, to: image) }
        let level = fade(at: outputTime, length: s.outputLength, fadeIn: s.fadeIn, fadeOut: s.fadeOut)
        if level < 1 {
            let l = CGFloat(level)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: l, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: l, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: l, w: 0),
            ])
        }
        let sourceTime = s.start + outputTime * s.speed
        if let cue = s.subtitles.first(where: { $0.start <= sourceTime && sourceTime < $0.end }),
           let text = Subtitles.overlay(cue, size: crop.size) {
            image = text.transformed(by: CGAffineTransform(translationX: 0, y: crop.height * 0.08)).composited(over: image)
        }
        return image.cropped(to: CGRect(origin: .zero, size: crop.size))
    }

    // MARK: AVFoundation

    /// A composition that draws every frame through `frame`, reading the settings as they are at that moment, so a
    /// preview follows the controls without being rebuilt. `preview` frames come in source time; an export's in
    /// result time.
    static func videoComposition(for asset: AVAsset, settings: OSAllocatedUnfairLock<VideoSettings>, preview: Bool,
                                 upright: CGSize) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let s = settings.withLock { $0 }
            let time = request.compositionTime.seconds
            let output = preview ? (time - s.start) / s.speed : time
            request.finish(with: frame(request.sourceImage, s, outputTime: output), context: nil)
        }
        composition.renderSize = renderSize(upright: upright, settings.withLock { $0 })
        return composition
    }

    static func renderSize(upright: CGSize, _ s: VideoSettings) -> CGSize {
        cropRect(in: turnedSize(upright, quarterTurns: s.quarterTurns), ratio: s.ratio, position: s.position).size
    }

    /// The track's picture size once its own transform is applied.
    static func uprightSize(of track: AVAssetTrack) async throws -> CGSize {
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Volume and fades for `track`. In a preview the cut starts at `start` and runs `speed` times faster.
    static func audioMix(for track: AVAssetTrack, _ s: VideoSettings, preview: Bool) -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let volume = Float(s.removeAudio ? 0 : s.volume)
        let origin = preview ? s.start : 0, scale = preview ? s.speed : 1
        func at(_ seconds: Double) -> CMTime { CMTime(seconds: origin + seconds * scale, preferredTimescale: 600) }
        let envelope = Music.ramps(intervals: [], length: s.outputLength, volume: Double(volume), duckDB: 0,
                                   fadeIn: s.fadeIn, fadeOut: s.fadeOut, automaticFadeOut: false)
        parameters.setVolume(envelope.first?.from ?? volume, at: .zero)
        for ramp in envelope {
            parameters.setVolumeRamp(fromStartVolume: ramp.from, toEndVolume: ramp.to,
                                     timeRange: CMTimeRange(start: at(ramp.start), end: at(ramp.end)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Cuts, retimes and redraws `source` into a new file beside it ("clip trimmed.mp4", or "clip edited.mp4" when
    /// more than the cut changed). Sound keeps its pitch at any speed.
    static func export(_ source: URL, _ s: VideoSettings, isAudio: Bool) async throws -> URL {
        let asset = try await Video.safeAsset(source)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: s.start, preferredTimescale: 600),
                                end: CMTime(seconds: s.end, preferredTimescale: 600))
        var upright = CGSize.zero
        var hasVideo = false
        if !isAudio, let video = try await asset.loadTracks(withMediaType: .video).first {
            let track = try requireTrack(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(range, of: video, at: .zero)
            track.preferredTransform = try await video.load(.preferredTransform)
            upright = try await uprightSize(of: video)
            hasVideo = true
        }
        var cleanedAudio: URL?
        defer { if let cleanedAudio { MediaTemporaryFiles.discard(cleanedAudio) } }
        let originalAudio = try await asset.loadTracks(withMediaType: .audio).first
        let audioAsset: AVAsset
        if s.noiseReduction > 0, (!s.removeAudio || isAudio), originalAudio != nil {
            let url = try await NoiseReduction.cleanedPCM(source, strength: s.noiseReduction)
            cleanedAudio = url
            audioAsset = Video.openAsset(url)
        } else { audioAsset = asset }
        var audioTrack: AVMutableCompositionTrack?
        if !s.removeAudio || isAudio, let audio = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let track = try requireTrack(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(range, of: audio, at: .zero)
            audioTrack = track
        }
        guard hasVideo || audioTrack != nil else { throw ToolError(L("Nothing left to save.")) }
        if s.speed != 1 {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                       toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / s.speed))
        }

        var musicTrack: AVMutableCompositionTrack?
        var speech: [SpeechInterval] = []
        if let music = s.musicURL {
            musicTrack = try await Music.addTrack(to: composition, source: music, length: s.outputLength)
            if s.duckMusic, !s.removeAudio, s.volume > 0, audioTrack != nil {
                speech = try await SpeechActivity.detect(source).intervals
            }
        }

        let ext = source.pathExtension.lowercased()
        let (preset, type, outExt): (String, AVFileType, String)
        if !hasVideo {
            (preset, type, outExt) = (AVAssetExportPresetAppleM4A, .m4a, "m4a")
        } else {
            // Re-encoded rather than passed through: a passthrough cut starts at the previous keyframe and only hides
            // the frames before the start point behind an edit list, so "trimmed" footage would still be in the file.
            (preset, type, outExt) = (AVAssetExportPresetHighestQuality, ext == "mp4" ? .mp4 : ext == "m4v" ? .m4v : .mov,
                                      ext == "mp4" || ext == "m4v" ? ext : "mov")
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw ToolError("Can't trim this file") }
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: s.outputLength, preferredTimescale: 600))
        session.audioTimePitchAlgorithm = .spectral
        if hasVideo {
            try Subtitles.validate(s.subtitles, size: renderSize(upright: upright, s))
            // Always drawn through the composition, which also makes the export decode and re-encode.
            let lock = OSAllocatedUnfairLock(initialState: s)
            session.videoComposition = try await videoComposition(for: composition, settings: lock, preview: false, upright: upright)
        }
        var parameters: [AVAudioMixInputParameters] = []
        if let audioTrack, s.volume != 1 || s.fadeIn > 0 || s.fadeOut > 0 || musicTrack != nil {
            parameters += audioMix(for: audioTrack, s, preview: false).inputParameters
        }
        if let musicTrack { parameters.append(Music.parameters(track: musicTrack, settings: s, speech: speech)) }
        if !parameters.isEmpty { let mix = AVMutableAudioMix(); mix.inputParameters = parameters; session.audioMix = mix }
        return try await Paths.produce(Paths.preferred(for: source, ext: outExt, suffix: s.isTrimOnly ? " trimmed" : " edited")) {
            let target = $0
            try await withTaskCancellationHandler {
                try Task.checkCancellation(); try await session.export(to: target, as: type); try Task.checkCancellation()
            } onCancel: { session.cancelExport() }
        }
    }

    private static func requireTrack(_ track: AVMutableCompositionTrack?) throws -> AVMutableCompositionTrack {
        guard let track else { throw ToolError("Can't trim this file") }
        return track
    }
}
