import AVFoundation
import Foundation
import Testing
import os
@testable import Swivel

@Suite(.serialized)
struct MediaSafetyTests {
    @Test func oversizedPCMIsRefusedBeforeAnyAllocation() throws {
        let normal = try MediaTemporaryFiles.pcmBudget(rate: 48000, channels: 2, duration: 60)
        #expect(normal == 48_000 * 2 * 4 * 60 * 2 + 1_048_576)
        #expect(throws: (any Error).self) { try MediaTemporaryFiles.pcmBudget(rate: 384000, channels: 16, duration: 86400) }
        #expect(throws: (any Error).self) { try MediaTemporaryFiles.pcmBudget(rate: .nan, channels: 2, duration: 1) }
        #expect(throws: (any Error).self) { try MediaTemporaryFiles.pcmBudget(rate: 48000, channels: 0, duration: 1) }
        #expect(throws: (any Error).self) { try MediaTemporaryFiles.pcmBudget(rate: 48000, channels: 2, duration: .infinity) }
    }

    @Test func decodedPrivateSourceRemainsInsideAnOwnerOnlyWorkspace() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try MediaBatchFixtures.tone(in: folder, seconds: 0.25, channels: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let original = try Data(contentsOf: source)
        let decoded = try await AudioFiles.decode(source)
        let directory = decoded.deletingLastPathComponent()
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        #expect(directory.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
        #expect(directory != source.deletingLastPathComponent())
        let file = try AVAudioFile(forReading: decoded)
        #expect(file.length == 11025 && file.processingFormat.channelCount == 2)
        #expect(try Data(contentsOf: source) == original)
        MediaTemporaryFiles.discard(decoded)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func cancellationAndFailureRemoveTheEntirePrivateWorkspace() async throws {
        enum ProbeFailure: Error { case expected }
        let directory = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            return try await MediaTemporaryFiles.produce(ext: "caf") { target in
                directory.withLock { $0 = target.deletingLastPathComponent() }
                _ = try Paths.create(Data("private audio fixture".utf8), at: target)
                ready.continuation.yield(); ready.continuation.finish()
                try await Task.sleep(for: .seconds(30))
            }
        }
        for await _ in ready.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelledDirectory = try #require(directory.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: cancelledDirectory.path))
        await #expect(throws: ProbeFailure.self) {
            try await MediaTemporaryFiles.produce(ext: "m4a") { target in
                directory.withLock { $0 = target.deletingLastPathComponent() }
                _ = try Paths.create(Data("failed intermediate".utf8), at: target)
                throw ProbeFailure.expected
            }
        }
        let failedDirectory = try #require(directory.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: failedDirectory.path))
    }

    @Test func silentVideoIgnoresOriginalNoiseReductionAndCanKeepAddedMusic() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await MediaBatchFixtures.video(in: folder)
        let original = try Data(contentsOf: source)
        var settings = VideoSettings(); settings.end = 1; settings.noiseReduction = 0.75
        let silent = try await VideoEdit.export(source, settings, isAudio: false)
        #expect(try await Video.openAsset(silent).loadTracks(withMediaType: .audio).isEmpty)
        settings.musicURL = try MediaBatchFixtures.tone(in: folder, frequency: 880)
        let musical = try await VideoEdit.export(source, settings, isAudio: false)
        #expect(try await !Video.openAsset(musical).loadTracks(withMediaType: .audio).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }
}
