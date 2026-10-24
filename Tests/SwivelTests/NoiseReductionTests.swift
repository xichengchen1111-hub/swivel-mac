import AVFoundation
import Testing
@testable import Swivel

@Suite(.serialized)
struct NoiseReductionTests {
    private func noisy(in folder: URL) throws -> URL {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let count = 132300
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        pcm.frameLength = AVAudioFrameCount(count)
        var rng: UInt64 = 1739
        for c in 0..<2 { for i in 0..<count {
            rng = rng &* 6364136223846793005 &+ 1
            let noise = (Double((rng >> 32) & 65535) / 32767.5 - 1) * 0.10
            let tone = i >= 44100 ? 0.3 * sin(Double(i) * 440 * 2 * .pi / 44100) : 0
            pcm.floatChannelData![c][i] = Float((noise + tone) * (c == 0 ? 1 : 0.8))
        } }
        return try Paths.produce(folder.appendingPathComponent("talk.wav")) { target in
            let file = try AVAudioFile(forWriting: target, settings: format.settings)
            try file.write(from: pcm)
        }
    }
    private func samples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (0..<Int(file.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
    }
    private func meanSquare(_ values: [Float]) -> Double {
        values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))
    }
    @Test func noiseProfileRequiresLevelSeparationAndRejectsTonalContent() {
        let broad = [Float](repeating: 1, count: 1025)
        var tonal = [Float](repeating: 0.001, count: 1025); tonal[20] = 100
        #expect(NoiseReduction.isCredibleNoise(quietEnergy: 0.001, activeEnergy: 0.03, spectrum: broad))
        #expect(!NoiseReduction.isCredibleNoise(quietEnergy: 0.03, activeEnergy: 0.03, spectrum: broad))
        #expect(!NoiseReduction.isCredibleNoise(quietEnergy: 0.001, activeEnergy: 0.03, spectrum: tonal))
        #expect(!NoiseReduction.isCredibleNoise(quietEnergy: .nan, activeEnergy: 0.03, spectrum: broad))
        #expect(!NoiseReduction.isCredibleNoise(quietEnergy: 0.001, activeEnergy: 0.03, spectrum: [.infinity]))
    }
    @Test func cleanContinuousAndChangingLevelTonesAreNotMistakenForNoise() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        for frequency in [120.0, 440, 1800] { for modulated in [false, true] {
            let count = 66150
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for c in 0..<2 { for i in 0..<count {
                // A quiet, voiced section may still be a wanted signal. Its narrow spectrum protects it even
                // when its level is far below the loud section and would otherwise look like a noise sample.
                let level = modulated && i < count / 3 ? 0.04 : 0.3
                buffer.floatChannelData![c][i] = Float(level * (c == 0 ? 1 : 0.6) * sin(Double(i) * frequency * 2 * .pi / 44100))
            } }
            let source = try Paths.produce(folder.appendingPathComponent("clean-tone.wav")) { target in
                let file = try AVAudioFile(forWriting: target, settings: format.settings); try file.write(from: buffer)
            }
            let original = try Data(contentsOf: source), before = try samples(source)
            for strength in [0.75, 1.0] {
                let output = try Paths.produce(folder.appendingPathComponent("protected.caf")) {
                    try NoiseReduction.processPCM(source, to: $0, strength: strength)
                }
                let after = try samples(output)
                #expect(after.count == 2 && after[0].count == before[0].count)
                for c in 0..<2 {
                    let delta = 10 * log10(meanSquare(after[c]) / meanSquare(before[c]))
                    print("Clean \(frequency) Hz, changing level \(modulated), strength \(strength): \(delta) dB")
                    #expect(delta >= -3.01 && delta <= 0.05)
                }
            }
            #expect(try Data(contentsOf: source) == original)
        } }
    }
    @Test func toneAndNoiseWithoutANoiseOnlyIntroductionUsesConservativeReduction() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try noisy(in: folder), input = try AVAudioFile(forReading: fixture)
        input.framePosition = 44100 // Remove the fixture's entire noise-only introduction.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 88200))
        try input.read(into: buffer)
        let source = try Paths.produce(folder.appendingPathComponent("no-introduction.wav")) { target in
            let file = try AVAudioFile(forWriting: target, settings: input.processingFormat.settings); try file.write(from: buffer)
        }
        let before = try samples(source)
        let output = try Paths.produce(folder.appendingPathComponent("conservative.caf")) {
            try NoiseReduction.processPCM(source, to: $0, strength: 1)
        }
        let after = try samples(output)
        #expect(after.count == before.count && after[0].count == before[0].count)
        for c in 0..<before.count {
            let delta = 10 * log10(meanSquare(after[c]) / meanSquare(before[c]))
            #expect(delta >= -3.01 && delta <= 0.05)
        }
    }
    @Test func cleanLocalSpeechWithoutAddedSilenceKeepsItsLevelAndWaveform() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spoken = try await Paths.produce(folder.appendingPathComponent("spoken.aiff")) { target in
            try await Shell.run("/usr/bin/say", ["-v", "Samantha", "-o", target.path, "--",
                "The purple bicycle is beside the yellow house. We walk together and listen to the music."])
        }
        let file = try AVAudioFile(forReading: spoken)
        try #require(file.length > 0)
        let all = try samples(spoken)
        let first = try #require(all[0].firstIndex { abs($0) > 0.001 })
        let last = try #require(all[0].lastIndex { abs($0) > 0.001 })
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(last - first + 1)))
        buffer.frameLength = buffer.frameCapacity
        for c in all.indices { for i in first...last { buffer.floatChannelData![c][i - first] = all[c][i] } }
        let source = try Paths.produce(folder.appendingPathComponent("tight-speech.wav")) { target in
            let output = try AVAudioFile(forWriting: target, settings: file.processingFormat.settings); try output.write(from: buffer)
        }
        let bytes = try Data(contentsOf: source), before = try samples(source)
        let output = try Paths.produce(folder.appendingPathComponent("speech-clean.caf")) {
            try NoiseReduction.processPCM(source, to: $0, strength: 0.75)
        }
        let after = try samples(output)
        #expect(after.count == before.count && after[0].count == before[0].count)
        for c in before.indices {
            let delta = 10 * log10(meanSquare(after[c]) / meanSquare(before[c]))
            let error = meanSquare(zip(before[c], after[c]).map { $0 - $1 }) / meanSquare(before[c])
            print("Clean local speech: level \(delta) dB, relative waveform error \(error)")
            #expect(delta >= -3.01 && delta <= 0.05)
            #expect(error < 0.1)
        }
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func cancellationAfterSpectralOutputStartsRemovesThePartialFile() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try noisy(in: folder), bytes = try Data(contentsOf: source)
        let task = Task.detached {
            try Paths.produce(folder.appendingPathComponent("cancelled.caf")) { target in
                try NoiseReduction.processPCM(source, to: target, strength: 1) { progress in
                    if progress >= 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["talk.wav"])
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func cleanedPCMUsesPrivateStorageAndDiscardsItsDirectory() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try noisy(in: folder), bytes = try Data(contentsOf: source)
        let cleaned = try await NoiseReduction.cleanedPCM(source, strength: 0.75)
        let directory = cleaned.deletingLastPathComponent()
        defer { MediaTemporaryFiles.discard(cleaned) }
        #expect(directory != folder)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["talk.wav"])
        MediaTemporaryFiles.discard(cleaned)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func spectralReductionAttenuatesNoiseByTenDBAndKeepsTheToneWithinThreeDB() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try noisy(in: folder)
        let beforeBytes = try Data(contentsOf: source), before = try samples(source)
        let output = try Paths.produce(folder.appendingPathComponent("clean.caf")) {
            try NoiseReduction.processPCM(source, to: $0, strength: 1)
        }
        let after = try samples(output)
        #expect(after.count == 2 && after[0].count == before[0].count)
        func energy(_ a: [Float], _ range: Range<Int>) -> Double { range.reduce(0) { $0 + pow(Double(a[$1]), 2) } / Double(range.count) }
        func tone(_ a: [Float]) -> Double {
            let range = 57330..<123480
            var r = 0.0, i = 0.0
            for n in range { let phase = Double(n) * 440 * 2 * .pi / 44100; r += Double(a[n]) * cos(phase); i += Double(a[n]) * sin(phase) }
            return hypot(r, i)
        }
        for c in 0..<2 {
            let reduction = 10 * log10(energy(before[c], 8820..<35280) / energy(after[c], 8820..<35280))
            let change = 20 * log10(tone(after[c]) / tone(before[c]))
            print("Noise channel \(c): reduction \(reduction) dB; tone \(change) dB")
            #expect(reduction > 10)
            #expect(abs(change) < 3)
        }
        #expect(try Data(contentsOf: source) == beforeBytes)
    }
    @Test func zeroStrengthIsTransparentAndShortFilesStayTheSameLength() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try MediaBatchFixtures.tone(in: folder, seconds: 0.01, channels: 2)
        let before = try samples(source)
        let output = try Paths.produce(folder.appendingPathComponent("short.caf")) { try NoiseReduction.processPCM(source, to: $0, strength: 0) }
        let after = try samples(output)
        #expect(after[0].count == before[0].count && after.count == before.count)
        #expect(zip(before[0], after[0]).allSatisfy { abs($0 - $1) < 0.000001 })
    }
    @Test func multichannelAudioDecodesDenoisesAndExportsWithDuckedMusic() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let surround = try MediaBatchFixtures.tone(in: folder, seconds: 2, channels: 6)
        let pcm = try await AudioFiles.decode(surround)
        defer { MediaTemporaryFiles.discard(pcm) }
        let decoded = try AVAudioFile(forReading: pcm)
        #expect(decoded.processingFormat.channelCount == 6 && abs(Double(decoded.length) - 88200) <= 1)
        _ = try await SpeechActivity.detect(surround)
        let cleaned = try await NoiseReduction.cleanedPCM(surround, strength: 1)
        defer { MediaTemporaryFiles.discard(cleaned) }
        #expect(try AVAudioFile(forReading: cleaned).processingFormat.channelCount == 6)
        let music = try MediaBatchFixtures.tone(in: folder, seconds: 1, frequency: 880)
        var settings = VideoSettings(); settings.end = 2; settings.musicURL = music; settings.noiseReduction = 1
        let output = try await VideoEdit.export(surround, settings, isAudio: true)
        #expect(try await abs(Video.safeAsset(output).load(.duration).seconds - 2) < 0.05)
    }
    @Test func decodedAndSavedAudioKeepsChannelsDurationNamesAndInput() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try noisy(in: folder), before = try Data(contentsOf: source)
        let output = try await NoiseReduction.save(source, strength: 1)
        #expect(output.lastPathComponent == "talk clean.m4a")
        let asset = try await Video.safeAsset(output)
        #expect(try await abs(asset.load(.duration).seconds - 3) < 0.02)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let desc = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee.mChannelsPerFrame == 2)
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["talk clean.m4a", "talk.wav"])
        let cancelled = Task { try await NoiseReduction.save(source, strength: 1) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled denoise unexpectedly saved") } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["talk clean.m4a", "talk.wav"])
    }
    @Test func videoExportUsesTheSameReductionAndPreservesTiming() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try noisy(in: folder)
        let source = try await MediaBatchFixtures.video(in: folder, seconds: 3, audio: audio)
        let before = try Data(contentsOf: source)
        var s = VideoSettings(); s.start = 0.25; s.end = 2.75; s.speed = 1.25; s.fadeIn = 0.1; s.noiseReduction = 1
        #expect(!s.isTrimOnly)
        let output = try await VideoEdit.export(source, s, isAudio: false)
        let asset = try await Video.safeAsset(output)
        let resultDuration = try await asset.load(.duration).seconds
        print("Denoised video duration: \(resultDuration), expected \(s.outputLength)")
        #expect(abs(resultDuration - s.outputLength) < 0.02)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try Data(contentsOf: source) == before)
    }
    @Test @MainActor func menuOrderAndTranslationsAndMCPStayExplicit() throws {
        let source = URL(fileURLWithPath: "/nonexistent/talk.wav")
        let titles = Catalog.defaultItems(for: [source], mode: .tools).map(\.title)
        #expect(titles.firstIndex(of: "Reduce Noise") == titles.firstIndex(of: "Compress").map { $0 - 1 })
        #expect(Strings.table["Reduce Noise"]?.count == 3)
        #expect(!MCPCatalog.actions(for: [source]).contains { $0.id == "tools.Reduce Noise" })
    }
}
