import AVFoundation
import Foundation
import Testing
@testable import Swivel

/// Shared file fixtures for the media-batch integration tests. No windows or installed app are involved.
enum MediaBatchFixtures {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-Media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func tone(in folder: URL, seconds: Double = 1, frequency: Double = 440, channels: Int = 1) throws -> URL {
        let format = try #require(AudioFiles.pcmFormat(rate: 44100, channels: channels))
        let count = AVAudioFrameCount((seconds * 44100).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for c in 0..<channels { for i in 0..<Int(count) { buffer.floatChannelData![c][i] = Float(0.3 * sin(Double(i) * frequency * 2 * .pi / 44100)) } }
        return try Paths.produce(folder.appendingPathComponent("tone.wav")) { target in
            let file = try AVAudioFile(forWriting: target, settings: format.settings)
            try file.write(from: buffer)
        }
    }
    static func video(in folder: URL, seconds: Double = 1, audio: URL? = nil, width: Int = 320, height: Int = 240) async throws -> URL {
        let silent = try await Paths.produce(folder.appendingPathComponent("silent.mov")) { target in
            let writer = try AVAssetWriter(outputURL: target, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ToolError("Fixture failed") }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<Int((seconds * 12).rounded()) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                var pixel: CVPixelBuffer?
                #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixel) == kCVReturnSuccess)
                let buffer = try #require(pixel)
                CVPixelBufferLockBaseAddress(buffer, [])
                let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height { for x in 0..<width {
                    let i = y * stride + x * 4
                    base[i] = 80; base[i + 1] = UInt8(y % 256); base[i + 2] = UInt8(x % 256); base[i + 3] = 255
                } }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
            }
            input.markAsFinished(); await writer.finishWriting()
            #expect(writer.status == .completed)
        }
        guard let audio else { return silent }
        let composition = AVMutableComposition()
        for (file, type) in [(silent, AVMediaType.video), (audio, AVMediaType.audio)] {
            let asset = Video.openAsset(file)
            let source = try #require(try await asset.loadTracks(withMediaType: type).first)
            let duration = try await asset.load(.duration)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, CMTime(seconds: seconds, preferredTimescale: 600))), of: source, at: .zero)
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        return try await Paths.produce(folder.appendingPathComponent("clip.mov")) { try await session.export(to: $0, as: .mov) }
    }
}
