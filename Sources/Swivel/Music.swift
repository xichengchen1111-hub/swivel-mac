import AppKit
import AVFoundation
import SoundAnalysis
import os

struct SpeechInterval: Equatable, Sendable { var start: Double; var end: Double }
struct MusicSegment: Equatable, Sendable { var start: Double; var duration: Double }
struct MusicRamp: Equatable, Sendable { var start: Double; var end: Double; var from: Float; var to: Float }
struct SpeechActivityResult: Sendable { var intervals: [SpeechInterval]; var usedSystemClassifier: Bool }

enum Music {
    static func merge(_ intervals: [SpeechInterval], length: Double) -> [SpeechInterval] {
        guard length.isFinite, length > 0 else { return [] }
        let valid = intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .map { SpeechInterval(start: max(0, $0.start), end: min(length, $0.end)) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [SpeechInterval] = []
        for interval in valid {
            if let last = result.last, interval.start <= last.end || interval.start - last.end < 0.5 {
                result[result.count - 1].end = max(last.end, interval.end)
            } else { result.append(interval) }
        }
        return result
    }
    static func outputIntervals(_ intervals: [SpeechInterval], settings: VideoSettings) -> [SpeechInterval] {
        guard settings.speed.isFinite, settings.speed > 0 else { return [] }
        return merge(intervals.map { SpeechInterval(start: ($0.start - settings.start) / settings.speed,
                                                    end: ($0.end - settings.start) / settings.speed) }, length: settings.outputLength)
    }
    static func loopPlan(duration: Double, length: Double) throws -> [MusicSegment] {
        guard duration.isFinite, length.isFinite, duration > 0, length > 0, ceil(length / duration) <= 10000 else {
            throw ToolError(L("The music is empty or too short to loop this many times. Choose a longer recording."))
        }
        var segments: [MusicSegment] = [], cursor = 0.0
        while cursor < length - 1e-9 {
            let count = min(duration, length - cursor)
            segments.append(MusicSegment(start: cursor, duration: count)); cursor += count
        }
        return segments
    }
    /// Exact piecewise-linear minimum envelope, including crossings between adjacent attack/release ramps and
    /// the final fade. Ramps cover the timeline once and never overwrite one another in AVAudioMix.
    static func ramps(intervals: [SpeechInterval], length: Double, volume: Double, duckDB: Double, fadeIn: Double = 0, fadeOut: Double = 0.8, automaticFadeOut: Bool = true) -> [MusicRamp] {
        guard length.isFinite, length > 0 else { return [] }
        let speech = merge(intervals, length: length)
        let base = Float(volume.isFinite ? min(1, max(0, volume)) : 0)
        let duck = pow(10, min(0, max(-60, duckDB.isFinite ? duckDB : -12)) / 20)
        let attack = 0.3, release = 0.8
        let inLength = max(0, fadeIn.isFinite ? fadeIn : 0)
        let outLength = max(automaticFadeOut ? min(0.8, length) : 0, fadeOut.isFinite ? fadeOut : 0)
        let fadeStart = length - outLength
        func duckLevel(_ t: Double) -> Double {
            // Only the nearest previous and next intervals can contribute. Binary lookup avoids rescanning the
            // entire recording for every envelope corner when long files are adjusted in the preview.
            var low = 0, high = speech.count
            while low < high {
                let mid = (low + high) / 2
                if speech[mid].start <= t { low = mid + 1 } else { high = mid }
            }
            var value = 1.0
            if low > 0 {
                let previous = speech[low - 1]
                value = t <= previous.end ? duck : min(1, duck + (1 - duck) * (t - previous.end) / release)
            }
            if low < speech.count {
                let next = speech[low], begin = max(0, next.start - attack)
                if t >= begin {
                    value = min(value, 1 - (1 - duck) * (t - begin) / max(1e-9, next.start - begin))
                }
            }
            return max(duck, min(1, value))
        }
        func fade(_ t: Double) -> Double {
            min(inLength > 0 ? max(0, t / inLength) : 1, outLength > 0 ? min(1, max(0, (length - t) / outLength)) : 1)
        }
        var times = [0.0, length, fadeStart, inLength]
        if inLength > fadeStart { times.append(length * inLength / (inLength + outLength)) }
        for s in speech { times += [max(0, s.start - attack), s.start, s.end, min(length, s.end + release)] }
        for (left, right) in zip(speech, speech.dropFirst()) where right.start - left.end < attack + release {
            times.append((left.end * attack + right.start * release) / (attack + release))
        }
        times = Array(Set(times.map { min(length, max(0, $0)) })).sorted()
        // The final fade can cross a speech release; retain that corner too.
        var crossings: [Double] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 1e-9 {
            let x = duckLevel(a) - fade(a), y = duckLevel(b) - fade(b)
            if x * y < 0 { crossings.append(a + (b - a) * abs(x) / (abs(x) + abs(y))) }
        }
        times = Array(Set(times + crossings)).sorted()
        return zip(times, times.dropFirst()).filter { $1 - $0 > 1e-9 }.map { a, b in
            MusicRamp(start: a, end: b, from: base * Float(min(duckLevel(a), fade(a))),
                      to: base * Float(min(duckLevel(b), fade(b))))
        }
    }
    static func level(at time: Double, ramps: [MusicRamp]) -> Float {
        guard let first = ramps.first, let last = ramps.last else { return 0 }
        if time <= first.start { return first.from }
        if time >= last.end { return last.to }
        var low = 0, high = ramps.count - 1
        while low < high { let mid = (low + high) / 2; if ramps[mid].end < time { low = mid + 1 } else { high = mid } }
        let ramp = ramps[low], progress = Float((time - ramp.start) / (ramp.end - ramp.start))
        return ramp.from + (ramp.to - ramp.from) * min(1, max(0, progress))
    }
    static func parameters(track: AVAssetTrack, settings: VideoSettings, speech: [SpeechInterval]) -> AVAudioMixInputParameters {
        let result = AVMutableAudioMixInputParameters(track: track)
        let ranges = settings.duckMusic && !settings.removeAudio && settings.volume > 0 ? outputIntervals(speech, settings: settings) : []
        let envelope = ramps(intervals: ranges, length: settings.outputLength, volume: settings.musicVolume, duckDB: settings.duckDB, fadeIn: settings.fadeIn, fadeOut: settings.fadeOut)
        for r in envelope {
            result.setVolumeRamp(fromStartVolume: r.from, toEndVolume: r.to,
                timeRange: CMTimeRange(start: CMTime(seconds: r.start, preferredTimescale: 48000),
                                      end: CMTime(seconds: r.end, preferredTimescale: 48000)))
        }
        return result
    }
    static func addTrack(to composition: AVMutableComposition, source: URL, length: Double) async throws -> AVMutableCompositionTrack {
        let asset = try await Video.safeAsset(source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError(L("This file has no audio."))
        }
        let available = try await track.load(.timeRange)
        for segment in try loopPlan(duration: available.duration.seconds, length: length) {
            try Task.checkCancellation()
            try destination.insertTimeRange(CMTimeRange(start: available.start, duration: CMTime(seconds: segment.duration, preferredTimescale: 48000)),
                                            of: track, at: CMTime(seconds: segment.start, preferredTimescale: 48000))
        }
        return destination
    }
}

private final class SpeechObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [SpeechInterval] = []
    private var failure: Error?
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              (result.classification(forIdentifier: "speech")?.confidence ?? 0) >= 0.45 else { return }
        lock.lock(); defer { lock.unlock() }
        intervals.append(SpeechInterval(start: result.timeRange.start.seconds, end: result.timeRange.end.seconds))
    }
    func request(_ request: SNRequest, didFailWithError error: Error) { lock.lock(); failure = error; lock.unlock() }
    func result() throws -> [SpeechInterval] { lock.lock(); defer { lock.unlock() }; if let failure { throw failure }; return intervals }
}

enum SpeechActivity {
    static func detect(_ source: URL) async throws -> SpeechActivityResult {
        let asset = try await Video.safeAsset(source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return SpeechActivityResult(intervals: [], usedSystemClassifier: true) }
        let pcm = try await AudioFiles.decode(source)
        defer { MediaTemporaryFiles.discard(pcm) }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48000)
            request.overlapFactor = 0.5
            let observer = SpeechObserver(), analyzer = try SNAudioFileAnalyzer(url: pcm)
            try analyzer.add(request, withObserver: observer)
            let gate = OSAllocatedUnfairLock(initialState: false)
            let intervals: [SpeechInterval] = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.withLockUnchecked { cancelled in
                        if cancelled { continuation.resume(throwing: CancellationError()); return }
                        analyzer.analyze { reachedEnd in
                            do {
                                let intervals = try observer.result()
                                guard reachedEnd else { throw CancellationError() }
                                continuation.resume(returning: intervals)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
            } onCancel: { gate.withLockUnchecked { cancelled in cancelled = true; analyzer.cancelAnalysis() } }
            try Task.checkCancellation()
            return SpeechActivityResult(intervals: intervals, usedSystemClassifier: true)
        } catch {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { try energyIntervals(pcm) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            return SpeechActivityResult(intervals: result, usedSystemClassifier: false)
        }
    }
    /// Backup for systems that cannot load the built-in classifier: 20 ms energy/zero-crossing activity.
    static func energyIntervals(_ pcm: URL) throws -> [SpeechInterval] {
        let file = try AVAudioFile(forReading: pcm)
        let format = file.processingFormat, count = max(1, Int(format.sampleRate * 0.02))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        var frames: [(time: Double, energy: Double, crossings: Double)] = [], position = 0
        while position < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            var energy = 0.0, crossings = 0
            for channel in 0..<Int(format.channelCount) {
                let samples = buffer.floatChannelData![channel]
                var candidate = 0.0, zeros = 0
                for i in 0..<n { candidate += pow(Double(samples[i]), 2); if i > 0, samples[i] * samples[i - 1] < 0 { zeros += 1 } }
                if candidate > energy { energy = candidate; crossings = zeros }
            }
            frames.append((Double(position) / format.sampleRate, energy / Double(n), Double(crossings) / Double(n)))
            position += n
        }
        let sorted = frames.map(\.energy).sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 5]
        let threshold = max(0.00001, floor * 5)
        return Music.merge(frames.filter { $0.energy > threshold && $0.crossings > 0.005 && $0.crossings < 0.45 }
            .map { SpeechInterval(start: $0.time, end: $0.time + 0.02) }, length: Double(file.length) / format.sampleRate)
    }
}

/// An audio-only preview companion. The video player remains the master clock; a native AVPlayerLooper repeats
/// the music, and FrameDriver keeps its phase and the shared ducking envelope aligned after seeks/cut/speed changes.
@MainActor
final class MusicPreview {
    private let master: AVPlayer
    private let source: URL
    private let queue = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var musicDuration = 0.0, musicStart = 0.0
    private var selected: URL?
    private var loading: Task<Void, Never>?, analysis: Task<Void, Never>?
    private var speech: [SpeechInterval] = [], hasAnalysis = false
    private var settings = VideoSettings()
    private var envelope: [MusicRamp] = []
    private var generation = 0
    private var analysisGeneration = 0
    private var closed = false
    private var seeking = false
    private let driver: FrameDriver
    var onStatus: ((String) -> Void)?
    init(master: AVPlayer, view: NSView, source: URL) {
        self.master = master; self.source = source
        driver = FrameDriver(view: view)
        driver.onFrame = { [weak self] _ in self?.tick() ?? false }
    }
    func update(_ settings: VideoSettings) {
        self.settings = settings
        if selected != settings.musicURL {
            generation += 1; seeking = false; loading?.cancel(); queue.pause(); looper = nil; queue.removeAllItems(); musicDuration = 0
            selected = settings.musicURL
            if let url = selected {
                let token = generation
                onStatus?(L("Preparing music preview…"))
                loading = Task { [weak self] in
                    do {
                        let asset = try await Video.safeAsset(url)
                        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError(L("This file has no audio.")) }
                        let range = try await track.load(.timeRange)
                        guard range.duration.seconds > 0 else { throw ToolError(L("This file has no audio.")) }
                        guard let self, !Task.isCancelled, !self.closed, token == self.generation else { return }
                        self.musicStart = range.start.seconds; self.musicDuration = range.duration.seconds
                        self.looper = AVPlayerLooper(player: self.queue, templateItem: AVPlayerItem(asset: asset), timeRange: range)
                        self.onStatus?(""); self.driver.start()
                    } catch {
                        guard let self, !Task.isCancelled, !self.closed else { return }
                        self.onStatus?(error.localizedDescription)
                    }
                }
            } else { onStatus?("") }
        }
        let needsAnalysis = selected != nil && settings.duckMusic && !settings.removeAudio && settings.volume > 0
        if !needsAnalysis, let running = analysis {
            analysisGeneration += 1; running.cancel(); analysis = nil; onStatus?("")
        }
        if needsAnalysis, !hasAnalysis, analysis == nil {
            analysisGeneration += 1
            let token = analysisGeneration
            onStatus?(L("Analyzing speech for music preview…"))
            analysis = Task { [weak self, source] in
                do {
                    let result = try await SpeechActivity.detect(source)
                    guard let self, !Task.isCancelled, !self.closed, token == self.analysisGeneration else { return }
                    self.speech = result.intervals; self.hasAnalysis = true; self.analysis = nil
                    self.rebuild(); self.onStatus?(""); self.driver.start()
                } catch {
                    guard let self, !Task.isCancelled, !self.closed, token == self.analysisGeneration else { return }
                    self.analysis = nil; self.onStatus?(error.localizedDescription)
                }
            }
        }
        rebuild(); driver.start()
    }
    private func rebuild() {
        let intervals = settings.duckMusic && !settings.removeAudio && settings.volume > 0 ? Music.outputIntervals(speech, settings: settings) : []
        envelope = Music.ramps(intervals: intervals, length: settings.outputLength, volume: settings.musicVolume, duckDB: settings.duckDB, fadeIn: settings.fadeIn, fadeOut: settings.fadeOut)
    }
    func playbackChanged() { if master.rate == 0 { queue.pause() }; driver.start() }
    private func tick() -> Bool {
        guard !closed, selected != nil, musicDuration > 0 else { queue.pause(); return false }
        let time = (master.currentTime().seconds - settings.start) / settings.speed
        guard time.isFinite, time >= 0, time < settings.outputLength, master.rate > 0 else { queue.pause(); return false }
        let expected = musicStart + time.truncatingRemainder(dividingBy: musicDuration)
        let actual = queue.currentTime().seconds
        let delta = abs(actual - expected)
        let circular = min(delta, abs(musicDuration - delta))
        if actual.isFinite, circular > 0.08, !seeking {
            seeking = true
            let token = generation
            queue.seek(to: CMTime(seconds: expected, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, token == self.generation, !self.closed else { return }
                    self.seeking = false
                }
            }
        }
        queue.volume = Music.level(at: time, ramps: envelope)
        if queue.rate == 0 { queue.play() }
        return true
    }
    func stop() {
        closed = true; generation += 1; analysisGeneration += 1; loading?.cancel(); analysis?.cancel(); driver.stop(); queue.pause(); looper = nil; queue.removeAllItems()
    }
}
