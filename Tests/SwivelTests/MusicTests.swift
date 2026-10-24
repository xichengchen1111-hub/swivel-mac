import AppKit
import AVFoundation
import Testing
@testable import Swivel

@Suite(.serialized)
struct MusicTests {
    @Test func intervalsMergeOverlapAndShortGapsButRespectTheHalfSecondBoundary() {
        let result = Music.merge([SpeechInterval(start: 0.8, end: 1), SpeechInterval(start: -1, end: 0.1),
            SpeechInterval(start: 0.05, end: 0.4), SpeechInterval(start: 1.5, end: 2),
            SpeechInterval(start: .nan, end: 9), SpeechInterval(start: 5, end: 10)], length: 6)
        #expect(result == [SpeechInterval(start: 0, end: 1), SpeechInterval(start: 1.5, end: 2), SpeechInterval(start: 5, end: 6)])
        #expect(Music.merge([], length: 1).isEmpty)
        #expect(Music.merge([SpeechInterval(start: 1, end: 0)], length: 1).isEmpty)
        var s = VideoSettings(); s.start = 1; s.end = 7; s.speed = 2
        #expect(Music.outputIntervals([SpeechInterval(start: 1.5, end: 3), SpeechInterval(start: 4, end: 9)], settings: s) ==
                [SpeechInterval(start: 0.25, end: 1), SpeechInterval(start: 1.5, end: 3)])
        #expect(s.isTrimOnly == false)
        s = VideoSettings(); s.musicURL = URL(fileURLWithPath: "/tmp/music.wav")
        #expect(!s.isTrimOnly)
    }
    @Test func envelopeHasAttackReleaseCrossingsAndAnAutomaticFinalFade() throws {
        let duck = Float(pow(10, -12.0 / 20))
        let ramps = Music.ramps(intervals: [SpeechInterval(start: 2, end: 3), SpeechInterval(start: 3.6, end: 4)], length: 8, volume: 0.7, duckDB: -12)
        #expect(abs(Music.level(at: 1, ramps: ramps) - 0.7) < 0.00001)
        #expect(abs(Music.level(at: 1.85, ramps: ramps) - 0.7 * (1 + duck) / 2) < 0.00001)
        #expect(abs(Music.level(at: 2.5, ramps: ramps) - 0.7 * duck) < 0.00001)
        #expect(abs(Music.level(at: 7.6, ramps: ramps) - 0.35) < 0.00001)
        #expect(Music.level(at: 8, ramps: ramps) == 0)
        #expect(ramps.first?.start == 0 && ramps.last?.end == 8)
        for (a, b) in zip(ramps, ramps.dropFirst()) {
            #expect(abs(a.end - b.start) < 0.000001 && abs(a.to - b.from) < 0.000001)
        }
        let merged = Music.ramps(intervals: [SpeechInterval(start: 2, end: 3), SpeechInterval(start: 3.2, end: 4)], length: 8, volume: 1, duckDB: -12)
        #expect(abs(Music.level(at: 3.1, ramps: merged) - duck) < 0.00001)
        let empty = Music.ramps(intervals: [], length: 8, volume: 1, duckDB: -12)
        #expect(Music.level(at: 3, ramps: empty) == 1 && Music.level(at: 8, ramps: empty) == 0)
        let tiny = Music.ramps(intervals: [SpeechInterval(start: 0, end: 0.1)], length: 0.1, volume: 1, duckDB: -12, fadeIn: 0.1)
        #expect(tiny.allSatisfy { $0.end > $0.start && $0.from.isFinite && $0.to.isFinite })
        #expect(Music.level(at: 0, ramps: tiny) == 0 && Music.level(at: 0.1, ramps: tiny) == 0)
    }
    @Test func musicLoopsAndTruncatesToExactLengthsWithoutUnboundedPlans() throws {
        #expect(try Music.loopPlan(duration: 3, length: 8) == [MusicSegment(start: 0, duration: 3), MusicSegment(start: 3, duration: 3), MusicSegment(start: 6, duration: 2)])
        #expect(try Music.loopPlan(duration: 20, length: 8) == [MusicSegment(start: 0, duration: 8)])
        #expect(throws: (any Error).self) { try Music.loopPlan(duration: 0, length: 8) }
        #expect(throws: (any Error).self) { try Music.loopPlan(duration: 0.000001, length: 8) }
    }
    @Test func longSpeechEnvelopesStayResponsiveAndMatchTheShortCase() {
        let intervals = (0..<16000).map { SpeechInterval(start: Double($0) * 2 + 0.5, end: Double($0) * 2 + 1) }
        let started = ContinuousClock.now
        let result = Music.ramps(intervals: intervals, length: 32000, volume: 0.7, duckDB: -12)
        let elapsed = started.duration(to: .now)
        print("16k speech envelope duration: \(elapsed)")
        #expect(elapsed < .seconds(3))
        #expect(abs(Music.level(at: 20000.75, ramps: result) - 0.7 * Float(pow(10, -12.0 / 20))) < 0.00001)
        #expect(abs(Music.level(at: 20001.9, ramps: result) - 0.7) < 0.00001)
    }
    @Test func fallbackFindsSpeechActivityInEitherChannelWithoutPhaseCancellation() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        func recording(channel: Int) throws -> URL {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
            buffer.frameLength = 88200
            for c in 0..<2 { buffer.floatChannelData![c].initialize(repeating: 0, count: 88200) }
            for i in 22050..<66150 { buffer.floatChannelData![channel][i] = Float(0.3 * sin(Double(i) * 880 * 2 * .pi / 44100)) }
            return try Paths.produce(folder.appendingPathComponent("channel\(channel).caf")) {
                let file = try AVAudioFile(forWriting: $0, settings: format.settings.merging([AVLinearPCMIsNonInterleaved: false]) { _, new in new })
                try file.write(from: buffer)
            }
        }
        let left = try SpeechActivity.energyIntervals(recording(channel: 0))
        let right = try SpeechActivity.energyIntervals(recording(channel: 1))
        #expect(!left.isEmpty && left == right)
        #expect(left.contains { $0.start <= 0.52 && $0.end >= 1.48 })
    }
    private func paddedSpeech(in folder: URL) async throws -> URL {
        let spoken = try await Paths.produce(folder.appendingPathComponent("spoken.aiff")) { output in
            try await Shell.run("/usr/bin/say", ["-v", "Samantha", "-o", output.path, "--", "The purple bicycle is beside the yellow house."])
        }
        let input = try AVAudioFile(forReading: spoken), format = input.processingFormat
        let count = AVAudioFrameCount(format.sampleRate * 8)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for c in 0..<Int(format.channelCount) { buffer.floatChannelData![c].initialize(repeating: 0, count: Int(count)) }
        let data = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: data)
        let offset = Int(format.sampleRate * 2), copied = min(Int(data.frameLength), Int(count) - offset)
        for c in 0..<Int(format.channelCount) { for i in 0..<copied { buffer.floatChannelData![c][offset + i] = data.floatChannelData![c][i] } }
        return try Paths.produce(folder.appendingPathComponent("padded.caf")) { output in
            let file = try AVAudioFile(forWriting: output, settings: format.settings.merging([AVLinearPCMIsNonInterleaved: false]) { _, new in new })
            try file.write(from: buffer)
        }
    }
    private func rms(_ source: URL, at time: Double) async throws -> Double {
        let decoded = try await AudioFiles.decode(source)
        defer { MediaTemporaryFiles.discard(decoded) }
        let file = try AVAudioFile(forReading: decoded), rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition((time - 0.1) * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * 0.2)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        return sqrt((0..<count).reduce(0.0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) } / Double(count))
    }
    private func toneLevel(_ source: URL, at time: Double, frequency: Double) async throws -> Double {
        let decoded = try await AudioFiles.decode(source)
        defer { MediaTemporaryFiles.discard(decoded) }
        let file = try AVAudioFile(forReading: decoded), rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(max(0, (time - 0.1) * rate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * 0.2)))
        try file.read(into: buffer)
        var real = 0.0, imaginary = 0.0
        for i in 0..<Int(buffer.frameLength) {
            let angle = Double(i) * frequency * 2 * .pi / rate, sample = Double(buffer.floatChannelData![0][i])
            real += sample * cos(angle); imaginary += sample * sin(angle)
        }
        return 2 * hypot(real, imaginary) / Double(buffer.frameLength)
    }
    @Test func offlineSpeechAndRealAudioMixLowerMusicDuringSpeech() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let voice = try await paddedSpeech(in: folder)
        let speech = try await SpeechActivity.detect(voice)
        let merged = Music.merge(speech.intervals, length: 8)
        print("Speech activity: system classifier \(speech.usedSystemClassifier), intervals \(merged)")
        #expect(speech.usedSystemClassifier)
        let interval = try #require(merged.max { $0.end - $0.start < $1.end - $1.start })
        #expect(interval.start > 0.5 && interval.end < 6.5)
        let music = try MediaBatchFixtures.tone(in: folder, seconds: 1, frequency: 880)
        let musicBytes = try Data(contentsOf: music), voiceBytes = try Data(contentsOf: voice)
        let composition = AVMutableComposition()
        let track = try await Music.addTrack(to: composition, source: music, length: 8)
        #expect(abs(composition.duration.seconds - 8) < 0.0001)
        let truncated = AVMutableComposition()
        _ = try await Music.addTrack(to: truncated, source: music, length: 0.6)
        #expect(abs(truncated.duration.seconds - 0.6) < 0.0001)
        let fallback = try SpeechActivity.energyIntervals(voice)
        #expect(fallback.contains { $0.start >= 1.5 && $0.start < 4 && $0.end > 3 })
        var settings = VideoSettings(); settings.end = 8; settings.musicURL = music; settings.musicVolume = 1
        let mix = AVMutableAudioMix(); mix.inputParameters = [Music.parameters(track: track, settings: settings, speech: speech.intervals)]
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        session.audioMix = mix
        let isolated = try await Paths.produce(folder.appendingPathComponent("isolated-music.m4a")) { try await session.export(to: $0, as: .m4a) }
        let quiet = min(1, max(0.3, (interval.start - 0.3) / 2)), during = (interval.start + interval.end) / 2
        let before = try await rms(isolated, at: quiet), inside = try await rms(isolated, at: during)
        let delta = 20 * log10(inside / before)
        print("Actual AAC music during speech: \(delta) dB")
        #expect(delta < -8)
        #expect(try await abs(Video.openAsset(isolated).load(.duration).seconds - 8) < 0.02)
        let movie = try await MediaBatchFixtures.video(in: folder, seconds: 8, audio: voice)
        let original = try Data(contentsOf: movie)
        let output = try await VideoEdit.export(movie, settings, isAudio: false)
        let asset = try await Video.safeAsset(output)
        #expect(try await abs(asset.load(.duration).seconds - 8) < 0.02)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        let finalBefore = try await toneLevel(output, at: quiet, frequency: 880)
        let finalDuring = try await toneLevel(output, at: during, frequency: 880)
        let finalDucking = 20 * log10(finalDuring / finalBefore)
        print("Final video music at 880 Hz during speech: \(finalDucking) dB")
        #expect(finalBefore > 0.2 && finalDucking < -6)
        var cut = settings; cut.start = 1; cut.end = 7; cut.speed = 2; cut.removeAudio = true
        let shortened = try await VideoEdit.export(movie, cut, isAudio: false)
        let cutAsset = try await Video.safeAsset(shortened)
        #expect(try await abs(cutAsset.load(.duration).seconds - 3) < 0.02)
        #expect(try await !cutAsset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try Data(contentsOf: movie) == original && Data(contentsOf: voice) == voiceBytes && Data(contentsOf: music) == musicBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".swivel-") })
    }
    @Test func cancellationCleansAnalysisAndVideoTemporaries() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let music = try MediaBatchFixtures.tone(in: folder, seconds: 60)
        let immediate = Task { try await SpeechActivity.detect(music) }
        immediate.cancel()
        await #expect(throws: (any Error).self) { try await immediate.value }
        let detection = Task { try await SpeechActivity.detect(music) }
        // Exercise cancellation after native work begins too. A faster machine may finish before this request;
        // either completion is valid, but cancellation must leave no hidden PCM behind.
        try await Task.sleep(for: .milliseconds(100))
        detection.cancel()
        do { _ = try await detection.value }
        catch { #expect(error is CancellationError || error is Cancelled) }
        let movie = try await MediaBatchFixtures.video(in: folder)
        var settings = VideoSettings(); settings.end = 1; settings.musicURL = music
        let export = Task { try await VideoEdit.export(movie, settings, isAudio: false) }
        export.cancel()
        await #expect(throws: (any Error).self) { try await export.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy {
            !$0.hasPrefix(".swivel-") && !$0.contains(" edited")
        })
    }
    @Test @MainActor func soundPageOffersMusicAndAllNewControlsAreTranslated() async throws {
        let source = URL(fileURLWithPath: "/nonexistent/clip.mov")
        let editor = try await TrimEditor(source: source)
        defer { editor.didClose() }
        func controls(_ view: NSView) -> [NSControl] { view.subviews.flatMap { ($0 as? NSControl).map { [$0] } ?? controls($0) } }
        let buttons = controls(editor.controls).compactMap { $0 as? NSButton }.map(\.title)
        #expect(buttons.contains(L("Choose Music…")) && buttons.contains(L("Lower music when someone speaks")))
        for key in ["Music", "Music Volume", "Choose Music…", "Remove Music", "Lower music when someone speaks", "Duck by", "Preparing music preview…", "Analyzing speech for music preview…"] {
            #expect(Strings.table[key]?.count == 3)
        }
    }
}
