import Foundation
import Darwin
import os

/// Decoded audio must not inherit a shared source directory's visibility. Each intermediate lives under a
/// private 0700 directory in the user's temporary area; only finished, explicitly requested results go beside inputs.
enum MediaTemporaryFiles {
    static let minimumFreeBytes: Int64 = 1_073_741_824
    static let maximumJobBytes: Int64 = 17_179_869_184
    private struct Entry { let directory: URL; let reserved: Int64 }
    private struct State { var entries: [URL: Entry] = [:]; var reserved: Int64 = 0 }
    private static let lock = OSAllocatedUnfairLock(initialState: State())

    static func pcmBudget(rate: Double, channels: Int, duration: Double, copies: Int = 2) throws -> Int64 {
        guard rate.isFinite, (8000...384000).contains(rate), (1...16).contains(channels),
              duration.isFinite, duration > 0, duration <= 86400, (1...2).contains(copies) else {
            throw ToolError(L("This audio format or duration is not supported."))
        }
        let bytes = ceil(rate * duration) * Double(channels * 4 * copies) + 1_048_576
        guard bytes.isFinite, bytes <= Double(maximumJobBytes) else {
            throw ToolError(L("This recording needs too much temporary storage. Choose a shorter recording."))
        }
        return Int64(bytes)
    }

    static func freeBytes(in directory: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { throw ToolError(L("Couldn't check temporary storage space.")) }
        let amount = Double(info.f_bavail) * Double(info.f_bsize)
        return Int64(min(Double(Int64.max / 2), amount))
    }

    static func ensureSpace(at file: URL, writing bytes: Int64 = 0) throws {
        guard try freeBytes(in: file.deletingLastPathComponent()) >= minimumFreeBytes + max(0, bytes) else {
            throw ToolError(L("Not enough free space for temporary audio. At least 1 GB must remain free."))
        }
    }

    static func produce(ext: String, budgetBytes: Int64 = 0,
                        _ make: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let free = try freeBytes(in: parent)
        // Reservations include concurrent previews/exports. Existing bytes may be counted twice; this deliberately
        // errs toward refusing an oversized job instead of allowing concurrent decodes to fill the volume.
        let fits = lock.withLock { state in
            let fits = budgetBytes >= 0 && budgetBytes <= maximumJobBytes &&
                Double(free) >= Double(minimumFreeBytes) + Double(state.reserved) + Double(budgetBytes)
            if fits { state.reserved += budgetBytes }
            return fits
        }
        guard fits else { throw ToolError(L("Not enough free space for temporary audio. At least 1 GB must remain free.")) }
        let directory = Paths.temporary(beside: parent.appendingPathComponent("audio-work"), ext: "")
        var ownsDirectory = false
        do {
            guard mkdir(directory.path, 0o700) == 0 else { throw ToolError(L("Couldn't create private temporary audio storage.")) }
            ownsDirectory = true
            let url = try await Paths.produce(directory.appendingPathComponent("audio").appendingPathExtension(ext)) { target in
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await make(target) }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .milliseconds(250))
                            try ensureSpace(at: target)
                        }
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                try Task.checkCancellation()
            }
            lock.withLock { $0.entries[url] = Entry(directory: directory, reserved: budgetBytes) }
            return url
        } catch {
            if ownsDirectory { Paths.discard(directory) } else { TemporaryItems.unregister(directory) }
            lock.withLock { $0.reserved -= budgetBytes }
            throw error
        }
    }

    static func discard(_ file: URL) {
        let entry = lock.withLock { state -> Entry? in
            let entry = state.entries.removeValue(forKey: file)
            if let entry { state.reserved -= entry.reserved }
            return entry
        }
        if let entry { Paths.discard(entry.directory) }
    }
}
