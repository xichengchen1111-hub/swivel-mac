import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
@MainActor
struct FileSafetyTests {
    @Test func boundedReadsRefuseHugeSparseFilesAndLinksBeforeAllocation() throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("large.pdf")
        #expect(fm.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: 300 * 1024 * 1024); try file.close()
        #expect(throws: (any Error).self) { try PDFPagesSnapshot.load([source]) }
        #expect(throws: (any Error).self) { try PDFs.open(source) }
        #expect(try fm.attributesOfItem(atPath: source.path)[.size] as? Int == 300 * 1024 * 1024)
        let small = dir.appendingPathComponent("small.txt"), link = dir.appendingPathComponent("link.txt")
        try Data("safe".utf8).write(to: small)
        try fm.createSymbolicLink(at: link, withDestinationURL: small)
        #expect(throws: (any Error).self) { try FileSafety.read(link, limit: 100) }
        #expect(try FileSafety.read(small, limit: 4) == Data("safe".utf8))
        #expect(throws: (any Error).self) { try FileSafety.read(small, limit: 3) }
    }

    @Test func conversionLossesHaveThreeTranslationsAndAppearInPlans() async throws {
        for (path, title) in [("a.png", "JPG"), ("a.pdf", "Compress"), ("a.docx", "PDF"), ("a.mov", "GIF"),
                              ("a.wav", "M4A"), ("a.wav", "FLAC"), ("a.txt", "TAR.GZ"), ("a.mov", "WAV")] {
            let notes = ConversionNotice.messages(title: title, urls: [URL(fileURLWithPath: "/" + path)])
            #expect(!notes.isEmpty)
            for note in notes { #expect(Strings.table[note]?.count == 3) }
        }
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("note.txt")
        try Data("text".utf8).write(to: source)
        let tools = MCPTools(history: MCPHistory(directory: dir.appendingPathComponent("history")))
        let plan = try await tools.call("plan_action", ["action": "convert.PDF", "paths": [source.path]])
        #expect((plan["note"] as? String)?.contains("Letter") == true)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("note.pdf").path))
    }
    private let fm = FileManager.default
    private func folder() throws -> URL { try MediaBatchFixtures.folder().resolvingSymlinksInPath() }
    private func clean(_ dir: URL) throws {
        #expect(try fm.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".swivel-") })
    }
    private func mode(_ url: URL) throws -> Int { try #require(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }
    private func image(_ colour: CGFloat, depth: Int = 8) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: depth, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | (depth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)))
        context.setFillColor(CGColor(red: colour, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return try #require(context.makeImage())
    }
    private func images(_ url: URL, type: UTType, count: Int = 1, depth: Int = 8) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        for i in 0..<count {
            CGImageDestinationAddImage(dest, try image(CGFloat(i + 1) / CGFloat(count + 1), depth: depth), [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Safety fixture"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 27.4, kCGImagePropertyGPSLatitudeRef: "S"],
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
    }
    private func xattr(_ key: String, at url: URL) -> Data? {
        let n = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, key, &bytes, n, 0, XATTR_NOFOLLOW) == n else { return nil }
        return Data(bytes)
    }

    @Test func failedShortWriteAndFailedProducerLeaveNoFinalFile() throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.txt"), target = dir.appendingPathComponent("converted.rtf")
        let original = Data("original must survive".utf8)
        try original.write(to: source)
        var calls = 0
        #expect(throws: (any Error).self) {
            try Paths.produce(target) { work in
                #expect(try mode(work.deletingLastPathComponent()) & 0o777 == 0o700)
                try FileSafety.write(Data(repeating: 42, count: 4096), to: work) { fd, buffer, count in
                    calls += 1
                    if calls == 1 { return Darwin.write(fd, buffer, min(count, 1024)) }
                    errno = ENOSPC; return -1
                }
            }
        }
        #expect(!fm.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: source) == original)
        #expect(throws: (any Error).self) {
            try Paths.produce(target) { work in
                try Data("partial encoder output".utf8).write(to: work)
                throw ToolError("encoder failed")
            }
        }
        #expect(!fm.fileExists(atPath: target.path))
        try clean(dir)
    }

    @Test func generatedOutputsArePrivateIncludingInheritedACLs() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        try await Shell.run("/bin/chmod", ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit", dir.path])
        let out = try Paths.create(Data("private".utf8), at: dir.appendingPathComponent("result.txt"))
        #expect(try mode(out) & 0o777 == 0o600)
        if let acl = acl_get_file(out.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            #expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0)
        } else { #expect(errno == ENOENT || errno == ENOATTR) }
        let picture = dir.appendingPathComponent("source.png")
        try images(picture, type: .png)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: picture.path)
        let converted = try await Images.convert(picture, to: ImageFormat(name: "TIFF", type: .tiff, ext: "tiff"))
        #expect(try mode(converted[0]) & 0o777 == 0o600)
        try clean(dir)
    }

    @Test func cancellationAfterProducerFinishesStillDoesNotPublish() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let output = dir.appendingPathComponent("cancelled.dat")
        let task = Task {
            try await Paths.produce(output) { work in
                try Data("partial".utf8).write(to: work)
                try await Task.sleep(for: .seconds(10))
            }
        }
        await Task.yield(); task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!fm.fileExists(atPath: output.path))
        try clean(dir)
    }

    @Test func damagedZIPFailsBeforePublishingAndLeavesArchiveUntouched() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("payload.txt"), archive = dir.appendingPathComponent("broken.zip")
        let payload = Data("CRC-FIXTURE-12345".utf8)
        try payload.write(to: source)
        try await Shell.run("/usr/bin/zip", ["-0", "-q", archive.path, "--", source.lastPathComponent], in: dir)
        var data = try Data(contentsOf: archive)
        let range = try #require(data.range(of: payload))
        data.replaceSubrange(range, with: Data("CRC-FIXTURE-99999".utf8))
        try data.write(to: archive)
        await #expect(throws: (any Error).self) { try await Archives.extract(archive) }
        #expect(try Data(contentsOf: archive) == data)
        #expect(try Data(contentsOf: source) == payload)
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["payload.txt", "broken.zip"])
    }

    @Test func multiFileZIPKeepsResourceForksAttributesAndQuarantine() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let sources = [dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt")]
        for source in sources {
            try Data("body".utf8).write(to: source)
            #expect(setxattr(source.path, "com.swivel.safety", "attribute", 9, 0, 0) == 0)
            #expect(setxattr(source.path, "com.apple.ResourceFork", "resource", 8, 0, 0) == 0)
        }
        let archive = try await Archives.zip(sources)
        let quarantine = "0081;65500000;SwivelTest;"
        #expect(setxattr(archive.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0) == 0)
        let bytes = try Data(contentsOf: archive)
        let outputs = try await Archives.extract(archive)
        #expect(outputs.count == 2)
        for output in outputs {
            #expect(try Data(contentsOf: output) == Data("body".utf8))
            #expect(xattr("com.swivel.safety", at: output) == Data("attribute".utf8))
            #expect(xattr("com.apple.ResourceFork", at: output) == Data("resource".utf8))
            #expect(xattr("com.apple.quarantine", at: output) == Data(quarantine.utf8))
            #expect(try mode(output) & 0o077 == 0)
        }
        await #expect(throws: (any Error).self) { try await Archives.tar(sources) }
        #expect(try Data(contentsOf: archive) == bytes)
        for source in sources { #expect(xattr("com.apple.ResourceFork", at: source) == Data("resource".utf8)) }
        try clean(dir)
    }

    @Test func multiPageTIFFKeepsEveryPageAndAnimationIsRefused() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let tiff = dir.appendingPathComponent("pages.tiff"), gif = dir.appendingPathComponent("animation.gif")
        try images(tiff, type: .tiff, count: 2)
        try images(gif, type: .gif, count: 2)
        let original = try Data(contentsOf: tiff), animated = try Data(contentsOf: gif)
        let format = ImageFormat(name: "PNG", type: .png, ext: "png")
        let outputs = try await Images.convert(tiff, to: format)
        #expect(outputs.map(\.lastPathComponent) == ["pages 1.png", "pages 2.png"])
        #expect(try Data(contentsOf: outputs[0]) != Data(contentsOf: outputs[1]))
        for output in outputs { let upright = try Images.load(output); #expect(upright.width == 24 && upright.height == 32) }
        let predicted = try MCPCatalog.predict(.imagePages(ext: "png"), [tiff])
        #expect(predicted.files.count == 2)
        await #expect(throws: (any Error).self) { try await Images.convert(gif, to: format) }
        #expect(throws: (any Error).self) { try Images.load(gif) }
        #expect(throws: (any Error).self) { try Images.load(tiff) }
        #expect(throws: (any Error).self) { try Upscale.loadStill(gif, factor: 2) }
        #expect(throws: (any Error).self) { try MetadataEditor.cleaned(gif, .init(location: true, camera: false, date: false, author: false, everything: false)) }
        #expect(try Data(contentsOf: tiff) == original)
        #expect(try Data(contentsOf: gif) == animated)
        try clean(dir)
    }

    @Test func higherPrecisionAudioIsPreservedOrRefusedBeforePublication() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let tone = try MediaBatchFixtures.tone(in: dir, seconds: 0.1)
        let source = dir.appendingPathComponent("double.caf")
        try await Shell.run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEF64", tone.path, source.path])
        let original = try Data(contentsOf: source)
        let result = try await Audio.convert(source, to: #require(Audio.formats.first { $0.name == "WAV" }))[0]
        let file = try AVAudioFile(forReading: result)
        #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 64)
        await #expect(throws: (any Error).self) { try await AudioFiles.decode(source, preservePrecision: true) }
        await #expect(throws: (any Error).self) { try await Audio.convert(source, to: #require(Audio.formats.first { $0.name == "FLAC" })) }
        #expect(try Data(contentsOf: source) == original)
        try clean(dir)
    }

    @Test func conversionKeepsHighBitDepthColourAndSupportedMetadata() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("deep.tiff")
        try images(source, type: .tiff, depth: 16)
        let original = try Data(contentsOf: source)
        let outputs = try await Images.convert(source, to: ImageFormat(name: "PNG", type: .png, ext: "png"))
        let result = try #require(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        let decoded = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
        #expect(props[kCGImagePropertyDepth] as? Int == 16)
        #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        #expect(gps?[kCGImagePropertyGPSLatitude] as? Double == 27.4)
        await #expect(throws: (any Error).self) { try await Images.convert(source, to: ImageFormat(name: "JPG", type: .jpeg, ext: "jpg")) }
        #expect(try Data(contentsOf: source) == original)
        try clean(dir)
    }

    @Test func floatingPointAudioDoesNotGetQuantizedTo16Bits() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = try MediaBatchFixtures.tone(in: dir, seconds: 0.2, channels: 2)
        let original = try Data(contentsOf: source)
        for name in ["WAV", "AIFF", "CAF"] {
            let format = try #require(Audio.formats.first { $0.name == name })
            let out = try await Audio.convert(source, to: format)[0]
            let read = try AVAudioFile(forReading: out)
            let stream = read.fileFormat.streamDescription.pointee
            #expect(stream.mBitsPerChannel == 32)
            #expect(stream.mFormatFlags & kAudioFormatFlagIsFloat != 0)
            #expect(stream.mSampleRate == 44100 && stream.mChannelsPerFrame == 2)
            #expect(read.length == 8820)
            let expected = try AVAudioFile(forReading: source)
            let a = try #require(AVAudioPCMBuffer(pcmFormat: expected.processingFormat, frameCapacity: 8820))
            let b = try #require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: 8820))
            try expected.read(into: a); try read.read(into: b)
            for channel in 0..<2 { #expect(Array(UnsafeBufferPointer(start: a.floatChannelData![channel], count: 8820)) == Array(UnsafeBufferPointer(start: b.floatChannelData![channel], count: 8820))) }
        }
        #expect(try Data(contentsOf: source) == original)
        try clean(dir)
    }

    @Test func videoWAVUsesPCMAndLongGIFDoesNotSilentlyTruncate() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let audio = try MediaBatchFixtures.tone(in: dir, seconds: 0.5)
        let video = try await MediaBatchFixtures.video(in: dir, seconds: 0.5, audio: audio)
        let before = try Data(contentsOf: video)
        let action = try #require(Video.convertItems(sourceExt: ["mov"]).first { $0.title == "WAV" })
        let out = try await action.run(video)[0]
        let decoded = try AVAudioFile(forReading: out)
        #expect(decoded.fileFormat.streamDescription.pointee.mBitsPerChannel == 32)
        #expect(decoded.length > 20000)
        for duration in [30.01, Double.nan, Double.infinity, 0] { #expect(throws: (any Error).self) { try Video.validateGIFDuration(duration) } }
        try Video.validateGIFDuration(30)
        let long = try await MediaBatchFixtures.video(in: dir, seconds: 30.1, width: 32, height: 32)
        let gif = try #require(Video.convertItems(sourceExt: ["mov"]).first { $0.title == "GIF" })
        await #expect(throws: (any Error).self) { try await gif.run(long) }
        #expect(!fm.fileExists(atPath: long.deletingPathExtension().appendingPathExtension("gif").path))
        #expect(try Data(contentsOf: video) == before)
        try clean(dir)
    }

    @Test func compatibleVideoFormatChangeKeepsEveryCompressedSample() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = try await MediaBatchFixtures.video(in: dir, seconds: 0.5)
        let original = try Data(contentsOf: source)
        func packets(_ url: URL) async throws -> [Data] {
            let asset = try await Video.safeAsset(url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            #expect(reader.startReading())
            var result: [Data] = []
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) == 0 { continue } // empty timeline/edit marker
                let block = try #require(CMSampleBufferGetDataBuffer(sample))
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let size = bytes.count
                let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                #expect(status == noErr)
                result.append(bytes)
            }
            #expect(reader.status == .completed)
            return result
        }
        let before = try await packets(source)
        let result = try await Video.recontainer(source, type: .mp4, ext: "mp4")[0]
        #expect(try await packets(result) == before)
        #expect(before.count == 6)
        #expect(try Data(contentsOf: source) == original)
        try clean(dir)
    }

    @Test func integer24BitAudioSurvivesLosslessFormatsAndPCM() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let tone = try MediaBatchFixtures.tone(in: dir, seconds: 0.2)
        let source = dir.appendingPathComponent("precision.wav")
        try await Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI24", tone.path, source.path])
        let original = try Data(contentsOf: source)
        func samples(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let expected = try samples(source)
        for name in ["WAV", "AIFF", "CAF", "FLAC", "ALAC"] {
            let output = try await Audio.convert(source, to: #require(Audio.formats.first { $0.name == name }))[0]
            #expect(try samples(output) == expected, "\(name) must keep every sample")
            let pcm = try await Audio.convert(output, to: #require(Audio.formats.first { $0.name == "WAV" }))[0]
            let file = try AVAudioFile(forReading: pcm)
            let format = file.fileFormat
            #expect(format.streamDescription.pointee.mBitsPerChannel >= 24, "\(name): \(format)")
            #expect(try samples(pcm) == expected)
        }
        #expect(try Data(contentsOf: source) == original)
        try clean(dir)
    }

    @Test func partiallySuccessfulArchiveBatchIsReportedAndCanBeUndone() async throws {
        let dir = try folder(); defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.txt")
        try Data("keep".utf8).write(to: source)
        let good = try await Archives.zip([source]), bad = dir.appendingPathComponent("bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        let tools = MCPTools(history: MCPHistory(directory: dir.appendingPathComponent("history")), trash: { try fm.removeItem(at: $0) })
        let plan = try await tools.call("plan_action", ["action": "convert.Extract", "paths": [good.path, bad.path]])
        let result = try await tools.call("apply_plan", ["plan_id": try #require(plan["plan_id"] as? String)])
        let created = try #require(result["created"] as? [String])
        #expect(created.count == 1)
        #expect(result["failed"] != nil)
        let entry = try #require(result["entry_id"] as? String)
        _ = try await tools.call("undo", ["entry_id": entry])
        #expect(!fm.fileExists(atPath: created[0]))
        #expect(try Data(contentsOf: source) == Data("keep".utf8))
        #expect(fm.fileExists(atPath: good.path) && fm.fileExists(atPath: bad.path))
        try clean(dir)
    }
}
