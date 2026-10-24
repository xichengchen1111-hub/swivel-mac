import AppKit
import VideoToolbox
import AVFoundation
import os
import ImageIO
import UniformTypeIdentifiers

enum Video {
    static func convertItems(sourceExt: Set<String>) -> [FileOption] {
        var list: [FileOption] = []
        if !sourceExt.contains("mp4") {
            list.append(FileOption(title: "MP4") { try await recontainer($0, type: .mp4, ext: "mp4") })
        }
        if !sourceExt.contains("mov") {
            list.append(FileOption(title: "MOV") { try await recontainer($0, type: .mov, ext: "mov") })
        }
        list += [
            FileOption(title: "HEVC") { try await export($0, AVAssetExportPresetHEVCHighestQuality, .mp4, "mp4", suffix: " hevc") },
            FileOption(title: "M4V") { try await recontainer($0, type: .m4v, ext: "m4v") },
            FileOption(title: "GIF") { try await gif($0) },
            FileOption(title: "M4A") { try await export($0, AVAssetExportPresetAppleM4A, .m4a, "m4a") },
            FileOption(title: "WAV") { url in
                let pcm = try await AudioFiles.decode(url, preservePrecision: true)
                defer { MediaTemporaryFiles.discard(pcm) }
                return [try await Paths.produce(Paths.preferred(for: url, ext: "wav")) { wav in
                    // Decode directly to PCM: no AAC generation loss, no forced 16-bit quantization.
                    try await Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32", pcm.path, wav.path])
                }]
            },
            FileOption(title: "PNG Frame") { try await frame($0) },
        ]
        return list
    }

    static let toolItems: [FileOption] = [
        FileOption(title: "Compress") { try await compress([$0]).files },
        FileOption(title: "1080p") { try await export($0, AVAssetExportPreset1920x1080, .mp4, "mp4", suffix: " 1080p") },
        FileOption(title: "720p") { try await export($0, AVAssetExportPreset1280x720, .mp4, "mp4", suffix: " 720p") },
        FileOption(title: "480p") { try await export($0, AVAssetExportPreset640x480, .mp4, "mp4", suffix: " 480p") },
        FileOption(title: "Mute") { try await mute($0) },
        FileOption(title: "Extract Audio") { try await export($0, AVAssetExportPresetAppleM4A, .m4a, "m4a") },
        FileOption(title: "Frame") { try await frame($0) },
        FileOption(title: "GIF") { try await gif($0) },
    ]

    @MainActor
    static func compress(_ urls: [URL]) async throws -> ActionResult {
        let alert = NSAlert()
        alert.messageText = L("Compress Video")
        alert.informativeText = L("Choose a target file size.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: [L("Smaller file"), L("8 MB"), L("10 MB"), L("25 MB"), L("50 MB"), L("100 MB")])
        popup.selectItem(at: Prefs.videoCompressTargets.firstIndex(of: Prefs.videoCompressTarget) ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Compress"))
        alert.addButton(withTitle: L("Cancel"))
        // Dropping from Finder leaves Finder in front; the question must come forward to be seen.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { throw Cancelled() }
        let target = Prefs.videoCompressTargets[popup.indexOfSelectedItem]
        Prefs.videoCompressTarget = target
        var files: [URL] = [], messages: [String] = []
        do { for url in urls {
            let out: URL
            if target == 0 { out = try await compressSmaller(url) }
            else { out = try await compressToTarget(url, maxBytes: target) }
            files.append(out)
            let size = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            messages.append(target > 0 && size > target
                ? L("Saved %@ (%@), but the target size was exceeded.", out.lastPathComponent, byteString(size))
                : L("Saved %@ (%@)", out.lastPathComponent, byteString(size)))
        } } catch { throw PartialOutputError.wrapping(error, files: files) }
        return ActionResult(message: messages.joined(separator: "\n"), files: files)
    }

    private static func compressSmaller(_ url: URL) async throws -> URL {
        return try await Paths.produce(Paths.preferred(for: url, ext: "mp4", suffix: " compressed")) { temporary in
        guard let session = AVAssetExportSession(asset: try await safeAsset(url), presetName: AVAssetExportPresetMediumQuality) else {
            throw ToolError(L("Couldn't encode video."))
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: temporary, as: .mp4)
            try Task.checkCancellation()
        } onCancel: { session.cancelExport() }
        }
    }

    static func targetBitrates(maxBytes: Int, duration: Double, hasAudio: Bool) throws -> (video: Int, audio: Int) {
        guard duration.isFinite, duration > 0, maxBytes > 0 else {
            throw ToolError(L("Invalid video duration or target size."))
        }
        let total = Double(maxBytes) * 8 / duration * 0.95
        let audio = hasAudio ? (total < 1_000_000 ? 64_000 : 128_000) : 0
        guard total - Double(audio) >= 150_000 else {
            throw ToolError(L("Target size is too small for this video's duration."))
        }
        guard total < Double(Int.max) else { throw ToolError(L("Invalid video duration or target size.")) }
        return (Int(total) - audio, audio)
    }

    /// Encodes beside the source and publishes only a completed file. A second pass compensates for overshoot.
    static func compressToTarget(_ url: URL, maxBytes: Int) async throws -> URL {
        let asset = try await safeAsset(url)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let budget = try targetBitrates(maxBytes: maxBytes, duration: duration, hasAudio: audio != nil)
        var totalRate = Double(budget.video + budget.audio)
        let audioRate = budget.audio
        return try await Paths.produce(Paths.preferred(for: url, ext: "mp4", suffix: " compressed")) { temporary in
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let videoRate = totalRate - Double(audioRate)
            guard videoRate >= 150_000 else { throw ToolError(L("Target size is too small for this video's duration.")) }
            try await encodeTarget(asset, audio: audio, to: temporary, videoRate: Int(videoRate), audioRate: audioRate)
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size <= maxBytes { return }
            if attempt == 1 { throw ToolError(L("Target size cannot be reached. Smallest size: %@.", byteString(size))) }
            // Retry once, retaining the minimum supported video bitrate even when container overhead dominates.
            totalRate = max(Double(audioRate + 150_000), totalRate * Double(maxBytes) / Double(size) * 0.95)
            try FileManager.default.removeItem(at: temporary)
        }
        try Task.checkCancellation()
        }
    }

    private static func encodeTarget(_ asset: AVAsset, audio: AVAssetTrack?, to out: URL,
                                     videoRate: Int, audioRate: Int) async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError(L("No video track")) }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let cap = videoRate < 500_000 ? 640 : videoRate < 1_000_000 ? 854 : videoRate < 2_500_000 ? 1280 : 1920
        let scale = min(1, Double(cap) / max(bounds.width, bounds.height))
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        let fps = try await video.load(.nominalFrameRate)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, fps.rounded()))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(CGAffineTransform(scaleX: Double(width) / size.width,
                                             y: Double(height) / size.height), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoRate,
                kVTCompressionPropertyKey_DataRateLimits as String: [Double(videoRate) / 8, 1]]])
        // Keep the track's orientation/mirroring rather than baking it into the pixels.
        videoInput.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                                                tx: transform.tx * scale, ty: transform.ty * scale)
        var streams: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        if let audio {
            let descriptions = try await audio.load(.formatDescriptions)
            let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: min(2, max(1, Int(channels))), AVEncoderBitRateKey: audioRate])
            streams.append((output, input))
        }
        for (output, input) in streams {
            guard reader.canAdd(output), writer.canAdd(input) else { throw ToolError(L("Couldn't encode video.")) }
            reader.add(output); writer.add(input)
        }
        // Starting and cancelling never overlap: AVAssetReader crashes (EXC_BAD_ACCESS in startReading) when
        // cancelReading runs on another thread while it is still setting up. A cancel that comes first stops the start.
        let gate = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let started = try gate.withLockUnchecked { state -> Bool in
                    guard !state.cancelled else { return false }
                    guard writer.startWriting(), reader.startReading() else { throw reader.error ?? writer.error ?? ToolError(L("Couldn't encode video.")) }
                    state.started = true
                    return true
                }
                guard started else { throw CancellationError() }
                writer.startSession(atSourceTime: .zero)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (output, input) in streams {
                        group.addTask {
                            while true {
                                try Task.checkCancellation()
                                guard writer.status == .writing else { throw writer.error ?? ToolError(L("Couldn't encode video.")) }
                                if !input.isReadyForMoreMediaData {
                                    try await Task.sleep(for: .milliseconds(2))
                                    continue
                                }
                                let appended: Bool? = autoreleasepool {
                                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                                    return input.append(sample)
                                }
                                guard let appended else {
                                    if reader.status == .failed || reader.status == .cancelled {
                                        throw reader.error ?? CancellationError()
                                    }
                                    input.markAsFinished()
                                    return
                                }
                                if !appended { throw writer.error ?? ToolError(L("Couldn't encode video.")) }
                            }
                        }
                    }
                    for try await _ in group { }
                }
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw writer.error ?? ToolError(L("Couldn't encode video.")) }
            } catch {
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
                throw error
            }
        } onCancel: {
            gate.withLockUnchecked { state in
                state.cancelled = true
                guard state.started else { return }
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
            }
        }
    }

    static func export(_ url: URL, _ preset: String, _ type: AVFileType, _ ext: String,
                       suffix: String = "") async throws -> [URL] {
        try await export(try await safeAsset(url), preset, type, as: Paths.preferred(for: url, ext: ext, suffix: suffix))
    }

    /// A format change alone can copy the compressed samples. Editing, redaction and trimming never use this path.
    static func recontainer(_ url: URL, type: AVFileType, ext: String) async throws -> [URL] {
        let asset = try await safeAsset(url)
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                  with: asset, outputFileType: type)
        let preset = compatible ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        return try await export(asset, preset, type, as: Paths.preferred(for: url, ext: ext))
    }

    /// Exports into a temporary beside `preferred`, then publishes it there or under the next free name.
    private static func export(_ asset: AVAsset, _ preset: String, _ type: AVFileType, as preferred: URL) async throws -> [URL] {
        [try await Paths.produce(preferred) { try await encode(asset, preset, type, to: $0) }]
    }

    /// One export session writing a new file at `out`.
    private static func encode(_ asset: AVAsset, _ preset: String, _ type: AVFileType, to out: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError("This video can't be exported that way")
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: out, as: type)
            try Task.checkCancellation()
        } onCancel: { session.cancelExport() }
    }

    private static func mute(_ url: URL) async throws -> [URL] {
        let asset = try await safeAsset(url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError("No video track") }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try videoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack?.preferredTransform = try await track.load(.preferredTransform)
        return try await export(composition, AVAssetExportPresetHighestQuality, .mov,
                                as: Paths.preferred(for: url, ext: "mov", suffix: " muted"))
    }

    private static func generator(_ asset: AVAsset, maxSize: CGFloat? = nil) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxSize { generator.maximumSize = CGSize(width: maxSize, height: maxSize) }
        return generator
    }

    private static func frame(_ url: URL) async throws -> [URL] {
        let asset = try await safeAsset(url)
        let duration = try await asset.load(.duration).seconds
        let (image, _) = try await generator(asset).image(at: CMTime(seconds: duration * 0.1, preferredTimescale: 600))
        return [try Images.save(image, as: Paths.preferred(for: url, ext: "png", suffix: " frame"), type: .png, quality: 1)]
    }

    private static func gif(_ url: URL) async throws -> [URL] {
        let asset = try await safeAsset(url)
        let duration = try await asset.load(.duration).seconds
        try validateGIFDuration(duration)
        let fps = 12.0
        let count = max(Int((duration * fps).rounded(.up)), 1)
        let gen = generator(asset, maxSize: 540)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore

        // Frames stream into a temporary file rather than memory; it is published once complete.
        return [try await Paths.produce(Paths.preferred(for: url, ext: "gif")) { out in
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw ToolError("Couldn't create GIF")
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
            for i in 0..<count {
                try Task.checkCancellation()
                let (image, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
                CGImageDestinationAddImage(dest, image, frameProps)
            }
            guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't save GIF") }
        }]
    }

    static func validateGIFDuration(_ duration: Double) throws {
        guard duration.isFinite, duration > 0, duration <= 30 else {
            throw ToolError(L("GIF export supports clips up to 30 seconds. Use Trim to choose the full segment first."))
        }
    }
}

struct AudioFormat {
    let name: String
    let ext: String
    let args: [String]
}

enum Audio {
    static let formats: [AudioFormat] = [
        AudioFormat(name: "M4A", ext: "m4a", args: ["-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "110"]),
        AudioFormat(name: "WAV", ext: "wav", args: ["-f", "WAVE", "-d", "LEI16"]),
        AudioFormat(name: "AIFF", ext: "aiff", args: ["-f", "AIFF", "-d", "BEI16"]),
        AudioFormat(name: "FLAC", ext: "flac", args: ["-f", "flac", "-d", "flac"]),
        AudioFormat(name: "ALAC", ext: "m4a", args: ["-f", "m4af", "-d", "alac"]),
        AudioFormat(name: "CAF", ext: "caf", args: ["-f", "caff", "-d", "LEI16"]),
        AudioFormat(name: "AAC", ext: "aac", args: ["-f", "adts", "-d", "aac", "-s", "3", "-u", "vbrq", "110"]),
    ]

    static let toolItems: [FileOption] = [
        FileOption(title: "Compress") { url in
            try await run(url, ext: "m4a", suffix: " compressed", ["-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "40"])
        },
        FileOption(title: "Mono") { url in
            try await run(url, ext: "m4a", suffix: " mono", ["-f", "m4af", "-d", "aac", "-c", "1", "-s", "3", "-u", "vbrq", "90"])
        },
        FileOption(title: "Voice Memo") { url in
            try await run(url, ext: "m4a", suffix: " voice", ["-f", "m4af", "-d", "aac@22050", "-b", "48000", "-c", "1"])
        },
    ]

    static func convert(_ url: URL, to format: AudioFormat) async throws -> [URL] {
        let suffix = format.name == "ALAC" ? " lossless" : ""
        var args = format.args
        var validation: ((URL) throws -> Void)?
        if ["WAV", "AIFF", "CAF", "FLAC", "ALAC"].contains(format.name) {
            let source = try AVAudioFile(forReading: url)
            let sourceFormat = source.fileFormat
            let stream = sourceFormat.streamDescription.pointee
            let sourcePrecision = precision(sourceFormat, url: url)
            let exactFrames = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC].contains(stream.mFormatID) ? source.length : nil
            validation = { output in
                let result = try AVAudioFile(forReading: output)
                let resultFormat = result.fileFormat
                let description = resultFormat.streamDescription.pointee
                guard description.mSampleRate == stream.mSampleRate, description.mChannelsPerFrame == stream.mChannelsPerFrame,
                      sourcePrecision == 0 || precision(resultFormat, url: output) >= sourcePrecision,
                      exactFrames == nil || result.length == exactFrames else {
                    throw ToolError(L("The audio conversion could not preserve its precision, channels or duration."))
                }
            }
            let floating = stream.mFormatID == kAudioFormatLinearPCM && stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
            if ["FLAC", "ALAC"].contains(format.name) {
                guard !floating, stream.mBitsPerChannel <= 32 else {
                    throw ToolError(L("This lossless format cannot preserve floating-point audio. Use WAV or CAF instead."))
                }
                if format.name == "ALAC", let flags = [16: 1, 20: 2, 24: 3, 32: 4][Int(stream.mBitsPerChannel)] {
                    args[3] = "alac/\(flags)"
                }
            } else {
                // Preserve integer precision and float samples. Compressed sources decode to float32.
                let floatOutput = floating || stream.mFormatID != kAudioFormatLinearPCM
                let bits = floatOutput ? max(32, Int(stream.mBitsPerChannel)) : max(16, Int(stream.mBitsPerChannel))
                guard [16, 24, 32, 64].contains(bits) else { throw ToolError(L("This audio format or duration is not supported.")) }
                // Floating AIFF is AIFF-C; the extension remains .aiff and Core Audio identifies it correctly.
                if format.name == "AIFF", floatOutput { args[1] = "AIFC" }
                args[3] = (format.name == "AIFF" ? "BE" : "LE") + (floatOutput ? "F" : "I") + String(bits)
                if [kAudioFormatAppleLossless, kAudioFormatFLAC].contains(stream.mFormatID) { args[3] = "N" }
            }
        }
        return try await run(url, ext: format.ext, suffix: suffix, args, validate: validation)
    }

    private static func precision(_ format: AVAudioFormat, url: URL) -> UInt32 {
        let stream = format.streamDescription.pointee
        if stream.mFormatID == kAudioFormatAppleLossless {
            return [1: 16, 2: 20, 3: 24, 4: 32][stream.mFormatFlags] ?? 0
        }
        if stream.mBitsPerChannel > 0 { return stream.mBitsPerChannel }
        // FLAC's compressed ASBD reports zero; the file property carries its original sample precision.
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return 0 }
        defer { AudioFileClose(file) }
        var bits: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &bits) == noErr ? bits : 0
    }

    /// afconvert replaces whatever is at its output path, so it only ever writes a temporary.
    private static func run(_ url: URL, ext: String, suffix: String, _ args: [String], validate: ((URL) throws -> Void)? = nil) async throws -> [URL] {
        [try await Paths.produce(Paths.preferred(for: url, ext: ext, suffix: suffix)) { out in
            try await Shell.run("/usr/bin/afconvert", args + [url.path, out.path])
            try validate?(out)
        }]
    }
}
