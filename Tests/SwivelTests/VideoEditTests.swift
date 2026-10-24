import AppKit
import AVFoundation
import CoreImage
import Testing
@testable import Swivel

/// The video editor: crop, turns, fades, speed and sound, and the file it writes.
@Suite(.serialized)
@MainActor
struct VideoEditTests {
    @Test func overlappingSoundFadesMatchPictureAtCutAndSpeed() throws {
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        for length in [0.3, 3.0] {
            var settings = VideoSettings(); settings.start = 2; settings.end = 2 + length * 2
            settings.speed = 2; settings.fadeIn = 3; settings.fadeOut = 3
            for preview in [false, true] {
                let parameters = try #require(VideoEdit.audioMix(for: track, settings, preview: preview).inputParameters.first)
                for time in [length * 0.1, length * 0.5, length * 0.99] {
                    let timestamp = preview ? settings.start + time * settings.speed : time
                    var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
                    #expect(parameters.getVolumeRamp(for: CMTime(seconds: timestamp, preferredTimescale: 60000),
                        startVolume: &start, endVolume: &end, timeRange: &range))
                    let position = (timestamp - range.start.seconds) / range.duration.seconds
                    let actual = Double(start) + Double(end - start) * position
                    #expect(abs(actual - VideoEdit.fade(at: time, length: length, fadeIn: 3, fadeOut: 3)) < 0.001)
                }
            }
        }
    }
    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/video-edit-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Three seconds of 640 × 360 stored turned a quarter clockwise (upright 360 × 640), with a 440 Hz tone. Red
    /// grows along the stored x, which is downwards in the upright picture.
    private func clip(in folder: URL) async throws -> URL {
        let silent = folder.appendingPathComponent("silent.mp4")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ToolError("Fixture encoding failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<360 {
                for x in 0..<640 {
                    let offset = y * stride + x * 4
                    base[offset] = 255
                    base[offset + 1] = UInt8(x * 255 / 639)
                    base[offset + 2] = 60
                    base[offset + 3] = 60
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)

        let wav = folder.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300))
        pcm.frameLength = 132300
        for i in 0..<132300 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 44100) * 0.3) }
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: pcm) }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent), audioAsset = AVURLAsset(url: wav)
        let v = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let a = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 30))
        let vt = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try vt.insertTimeRange(range, of: v, at: .zero)
        vt.preferredTransform = try await v.load(.preferredTransform)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: a, at: .zero)
        let url = folder.appendingPathComponent("clip.mp4")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await session.export(to: url, as: .mp4)
        return url
    }

    private func facts(_ url: URL) async throws -> (duration: Double, size: CGSize, audio: Bool, top: Double, bottom: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await VideoEdit.uprightSize(of: video)
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600)).image
        var data = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let context = try #require(CGContext(data: &data, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                            bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        func red(row: Int) -> Double { Double(data[(row * frame.width + frame.width / 2) * 4]) }
        return (duration, size, audio, red(row: 4), red(row: frame.height - 5))
    }

    // MARK: Pure parts

    @Test func cropsAreTheLargestRatioRectangleInWholeEvenPixels() {
        let wide = CGSize(width: 1920, height: 1080)
        let tall = VideoEdit.cropRect(in: wide, ratio: 9.0 / 16, position: 0.5)
        #expect(tall.height == 1080 && tall.width == 606 && tall.minX == 657)
        #expect(VideoEdit.cropRect(in: wide, ratio: 9.0 / 16, position: 0).minX == 0)
        #expect(VideoEdit.cropRect(in: wide, ratio: 9.0 / 16, position: 1).maxX == 1920)
        // On a tall picture position 0 is the top: the high end of Core Image's bottom-up axis.
        let portrait = CGSize(width: 1080, height: 1920)
        let top = VideoEdit.cropRect(in: portrait, ratio: 1, position: 0)
        #expect(top.size == CGSize(width: 1080, height: 1080) && top.maxY == 1920)
        #expect(VideoEdit.cropRect(in: portrait, ratio: 1, position: 1).minY == 0)
        // Odd sizes come out even, and the whole picture is kept without a ratio.
        #expect(VideoEdit.cropRect(in: CGSize(width: 641, height: 359), ratio: nil, position: 0.5) == CGRect(x: 0, y: 0, width: 640, height: 358))
        for ratio in VideoEdit.ratios.compactMap(\.value) {
            let r = VideoEdit.cropRect(in: CGSize(width: 1280, height: 720), ratio: ratio, position: 0.3)
            #expect(Int(r.width) % 2 == 0 && Int(r.height) % 2 == 0)
            #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 1280 && r.maxY <= 720)
        }
    }

    @Test func fadesRiseAndFallOverTheirSeconds() {
        #expect(VideoEdit.fade(at: 0, length: 10, fadeIn: 2, fadeOut: 0) == 0)
        #expect(VideoEdit.fade(at: 1, length: 10, fadeIn: 2, fadeOut: 0) == 0.5)
        #expect(VideoEdit.fade(at: 5, length: 10, fadeIn: 2, fadeOut: 2) == 1)
        #expect(VideoEdit.fade(at: 9, length: 10, fadeIn: 2, fadeOut: 2) == 0.5)
        #expect(VideoEdit.fade(at: 10, length: 10, fadeIn: 0, fadeOut: 2) == 0)
        #expect(VideoEdit.fade(at: 3, length: 10, fadeIn: 0, fadeOut: 0) == 1)
    }

    @Test func framesTurnClockwiseAndFlipLikeTheyShould() throws {
        // 4 × 2 with a marker in the top-left pixel (Core Image's y is bottom-up: top row is y = 1).
        let base = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2))
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 1, width: 1, height: 1))
        let image = marker.composited(over: base)
        func redPixel(_ out: CIImage) throws -> CGPoint? {
            let context = CIContext()
            let w = Int(out.extent.width), h = Int(out.extent.height)
            var data = [UInt8](repeating: 0, count: w * h * 4)
            context.render(out, toBitmap: &data, rowBytes: w * 4, bounds: out.extent, format: .RGBA8, colorSpace: nil)
            for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4] > 200 { return CGPoint(x: x, y: y) } }
            return nil
        }
        var s = VideoSettings()
        s.end = 1
        let turned = { (q: Int, flip: Bool) -> CIImage in s.quarterTurns = q; s.flip = flip; return VideoEdit.frame(image, s, outputTime: 0.5) }
        // Rows of the bitmap run top-down. Top-left → (clockwise) top-right → bottom-right → bottom-left.
        #expect(turned(0, false).extent == CGRect(x: 0, y: 0, width: 4, height: 2))
        #expect(try redPixel(turned(0, false)) == CGPoint(x: 0, y: 0))
        #expect(turned(1, false).extent == CGRect(x: 0, y: 0, width: 2, height: 4))
        #expect(try redPixel(turned(1, false)) == CGPoint(x: 1, y: 0))
        #expect(try redPixel(turned(2, false)) == CGPoint(x: 3, y: 1))
        #expect(try redPixel(turned(3, false)) == CGPoint(x: 0, y: 3))
        #expect(try redPixel(turned(0, true)) == CGPoint(x: 3, y: 0))
        // A fade darkens the frame.
        s.quarterTurns = 0; s.flip = false; s.fadeIn = 1
        #expect(try redPixel(VideoEdit.frame(image, s, outputTime: 0.1)) == nil)
    }

    @Test func settingsKnowWhetherOnlyTheCutChanged() {
        var s = VideoSettings()
        s.end = 10
        #expect(s.isTrimOnly && s.outputLength == 10)
        s.speed = 2
        #expect(!s.isTrimOnly && s.outputLength == 5)
        s.speed = 1; s.ratio = 1
        #expect(!s.isTrimOnly && s.changesGeometry)
        s.ratio = nil; s.color.exposure = 0.3
        #expect(!s.isTrimOnly && !s.changesGeometry)
        for name in ["Trim", "Picture", "Speed", "Sound", "Color", "Position", "Volume", "Fade in", "Fade out", "Remove audio",
                     "Sound keeps its pitch."] + VideoEdit.colorFields {
            #expect(Strings.table[name] != nil, "\(name)")
        }
    }

    // MARK: Export

    @Test func anEditedVideoKeepsItsOrientationAndAppliesEveryChange() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await clip(in: directory)
        let original = try await facts(url)
        #expect(original.size == CGSize(width: 360, height: 640))
        // Upright, red grows downwards.
        #expect(original.bottom > original.top + 100)

        var s = VideoSettings()
        s.start = 0.5; s.end = 2.5; s.speed = 2; s.ratio = 1; s.position = 0.5; s.fadeIn = 0.2; s.volume = 0.5
        let edited = try await VideoEdit.export(url, s, isAudio: false)
        #expect(edited.lastPathComponent == "clip edited.mp4")
        let out = try await facts(edited)
        #expect(abs(out.duration - 1) < 0.1, "duration \(out.duration)")
        #expect(out.size == CGSize(width: 360, height: 360))
        #expect(out.audio)
        // Still upright: red grows downwards inside the square too.
        #expect(out.bottom > out.top + 40)

        // A turn makes it landscape; removing the sound leaves no audio track; only a cut is "trimmed".
        var turned = VideoSettings()
        turned.end = 3; turned.quarterTurns = 1; turned.removeAudio = true
        let sideways = try await facts(try await VideoEdit.export(url, turned, isAudio: false))
        #expect(sideways.size == CGSize(width: 640, height: 360) && !sideways.audio)
        var cut = VideoSettings()
        cut.start = 1; cut.end = 2
        let trimmed = try await VideoEdit.export(url, cut, isAudio: false)
        #expect(trimmed.lastPathComponent == "clip trimmed.mp4")
        #expect(abs(try await facts(trimmed).duration - 1) < 0.1)
    }

    @Test func audioFilesChangeSpeedAndFadeToo() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("talk.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        pcm.frameLength = 88200
        for i in 0..<88200 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 330 * 2 * .pi / 44100) * 0.3) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
        var s = VideoSettings()
        s.end = 2; s.speed = 2; s.fadeOut = 0.5
        let out = try await VideoEdit.export(url, s, isAudio: true)
        #expect(out.lastPathComponent == "talk edited.m4a")
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1, "duration \(duration)")
    }

    @Test func theEditorOffersEverySectionForVideoAndThreeForAudio() async throws {
        _ = NSApplication.shared
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await clip(in: directory)
        let editor = try await TrimEditor(source: url)
        defer { editor.didClose() }
        try await editor.load()
        #expect(!editor.isAudio && abs(editor.duration - 3) < 0.1)
        func segments(_ view: NSView) -> NSSegmentedControl? {
            for sub in view.subviews {
                if let control = sub as? NSSegmentedControl, control.segmentCount >= 3, control.label(forSegment: 0) == L("Trim") { return control }
                if let found = segments(sub) { return found }
            }
            return nil
        }
        #expect(segments(editor.controls)?.segmentCount == 6)
    }
}
