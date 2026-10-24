import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
@MainActor
struct TargetSizeTests {
    private func image(_ edge: Int = 1024) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                                            bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for i in 0..<(edge * edge) {
            for c in 0..<3 {
                seed = seed &* 1664525 &+ 1013904223
                bytes[i * 4 + c] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            bytes[i * 4 + 3] = 255
        }
        return try #require(context.makeImage())
    }

    @Test func jpegMeetsTargetAndLooserTargetImprovesQuality() throws {
        let source = try image()
        let small = try Images.encode(source, type: .jpeg, quality: 0.2).count
        let large = try Images.encode(source, type: .jpeg, quality: 0.8).count
        let tight = try Images.fitting(source, type: .jpeg, maxBytes: small)
        let loose = try Images.fitting(source, type: .jpeg, maxBytes: large)
        #expect(tight.data.count <= small)
        #expect(loose.data.count <= large)
        #expect(loose.quality > tight.quality)
        #expect(tight.longEdge == 1024 && loose.longEdge == 1024)
    }

    @Test func heicMeetsTarget() throws {
        let source = try image()
        let target = try Images.encode(source, type: .heic, quality: 0.4).count
        let result = try Images.fitting(source, type: .heic, maxBytes: target)
        #expect(result.data.count <= target)
        #expect(result.quality >= 0.05 && result.quality <= 0.95)
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(result.data as CFData, nil))) as String? == UTType.heic.identifier)
    }

    @Test func pngDownscalesAndRespectsFloor() throws {
        let source = try image()
        let target = try Images.encode(source, type: .png, quality: 1).count / 3
        let result = try Images.fitting(source, type: .png, maxBytes: target)
        #expect(result.data.count <= target)
        #expect(result.longEdge >= 320 && result.longEdge < 1024)
        let floor = try Images.resized(source, longEdge: 320)
        let minimum = try Images.encode(floor, type: .png, quality: 1).count
        let atFloor = try Images.fitting(source, type: .png, maxBytes: minimum)
        #expect(atFloor.longEdge == 320)
        #expect(throws: ToolError.self) { try Images.fitting(source, type: .png, maxBytes: minimum - 1) }
        do {
            _ = try Images.fitting(source, type: .png, maxBytes: 1)
            Issue.record("An unreachable target must fail")
        } catch {
            #expect(error.localizedDescription.contains(byteString(minimum)))
        }
        let tiny = try Images.fitting(image(100), type: .jpeg, maxBytes: 1_000_000)
        #expect(tiny.longEdge == 100) // Never enlarge a source smaller than the floor.
    }

    @Test func lossyDownscalesAndUnreachableTargetThrows() throws {
        for type in [UTType.jpeg, .heic] {
            let source = try image()
            let low = try Images.encode(source, type: type, quality: 0.05).count
            let result = try Images.fitting(source, type: type, maxBytes: low / 2)
            #expect(result.data.count <= low / 2)
            #expect(result.longEdge >= 320 && result.longEdge < 1024)
            #expect(throws: ToolError.self) { try Images.fitting(source, type: type, maxBytes: 1) }
        }
    }

    @Test func blankCutoutReturnsNoSubject() throws {
        let ctx = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        #expect(try Cutout.maskedImage(#require(ctx.makeImage())) == nil)
    }

    @Test func catalogOffersRemoveBGAfterAddBG() throws {
        let titles = Catalog.defaultItems(for: [URL(fileURLWithPath: "/nonexistent/photo.png")], mode: .tools).map(\.title)
        let add = try #require(titles.firstIndex(of: "Add BG"))
        #expect(titles[add + 1] == "Remove BG")
    }

    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/target-size-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func clip(in folder: URL, audio: Bool = false) async throws -> URL {
        let url = folder.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        // Exercise orientation preservation as well as scaling.
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ToolError("Fixture encoding failed") }; writer.startSession(atSourceTime: .zero)
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
                    base[offset + 1] = UInt8(truncatingIfNeeded: x + frame * 5)
                    base[offset + 2] = UInt8(truncatingIfNeeded: y + frame * 3)
                    base[offset + 3] = UInt8(truncatingIfNeeded: x ^ y ^ (frame * 7))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
        guard audio else { return url }
        let wav = folder.appendingPathComponent("audio.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300))
        pcm.frameLength = 132300
        for i in 0..<132300 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 44100) * 0.2) }
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: pcm) }
        let composition = AVMutableComposition()
        // Tracks only weakly reference their asset: keep both assets alive while the composition copies from them.
        let videoAsset = AVURLAsset(url: url), audioAsset = AVURLAsset(url: wav)
        let v = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let a = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 30))
        let vt = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try vt.insertTimeRange(range, of: v, at: .zero); vt.preferredTransform = try await v.load(.preferredTransform)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: a, at: .zero)
        let combined = folder.appendingPathComponent("with-audio.mp4")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await session.export(to: combined, as: .mp4)
        withExtendedLifetime((videoAsset, audioAsset)) {}
        return combined
    }

    @Test func videoMeetsTargetPreservesAudioAndOrientation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await clip(in: directory, audio: true)
        let original = try Data(contentsOf: source)
        let output = try await Video.compressToTarget(source, maxBytes: 240_000)
        #expect(try Data(contentsOf: output).count <= 240_000)
        #expect(output.deletingLastPathComponent() == source.deletingLastPathComponent())
        #expect(try Data(contentsOf: source) == original)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let visible = CGRect(origin: .zero, size: size).applying(transform)
        #expect(visible.height > visible.width)
        #expect(max(visible.width, visible.height) <= 854)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.2)
        let second = try await Video.compressToTarget(source, maxBytes: 240_000)
        #expect(second != output)
        #expect(try Data(contentsOf: output).count <= 240_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".swivel-") })
    }

    @Test func videoBudgetRejectsImpossibleTargetsBeforeEncoding() throws {
        #expect(throws: ToolError.self) { try Video.targetBitrates(maxBytes: 1000, duration: 3, hasAudio: false) }
        #expect(throws: ToolError.self) { try Video.targetBitrates(maxBytes: 8_000_000, duration: 600, hasAudio: true) }
        #expect(throws: ToolError.self) { try Video.targetBitrates(maxBytes: 0, duration: 3, hasAudio: false) }
        #expect(throws: ToolError.self) { try Video.targetBitrates(maxBytes: 1_000_000, duration: .nan, hasAudio: false) }
        let low = try Video.targetBitrates(maxBytes: 240_000, duration: 3, hasAudio: true)
        #expect(low.audio == 64_000 && low.video >= 150_000)
        let high = try Video.targetBitrates(maxBytes: 8_000_000, duration: 3, hasAudio: true)
        #expect(high.audio == 128_000)
        #expect(try Video.targetBitrates(maxBytes: 240_000, duration: 3, hasAudio: false).audio == 0)
    }

    @Test func impossibleVideoTargetAndCancellationLeaveNoPartialFiles() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await clip(in: directory)
        await #expect(throws: ToolError.self) { try await Video.compressToTarget(source, maxBytes: 1000) }
        // Cancelled before it starts: it must throw and leave nothing.
        let early = Task { try await Video.compressToTarget(source, maxBytes: 240_000) }
        early.cancel()
        do { _ = try await early.value; Issue.record("Cancelled encoding must throw") } catch { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mp4"])

        // Cancelled while running. Under a busy test run the sleep can outlast the whole encode, so either outcome
        // is allowed; what must never happen is a partial output or a leftover hidden temporary.
        let running = Task { try await Video.compressToTarget(source, maxBytes: 240_000) }
        try await Task.sleep(for: .milliseconds(20))
        running.cancel()
        let finished = (try? await running.value) != nil
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == (finished ? ["source compressed.mp4", "source.mp4"] : ["source.mp4"]), "\(left)")
    }
}
