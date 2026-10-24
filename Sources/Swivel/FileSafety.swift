import Foundation
import Darwin

/// A failed batch can still own completed outputs. Keep them available to the UI and MCP undo log.
struct PartialOutputError: LocalizedError {
    let files: [URL]
    let failures: [String]
    var errorDescription: String? {
        var lines = failures
        if !files.isEmpty { lines.append(L("Completed files were kept:\n%@", files.map(\.path).joined(separator: "\n"))) }
        return lines.joined(separator: "\n")
    }
    static func wrapping(_ error: Error, files: [URL]) -> Self {
        if let partial = error as? Self { return .init(files: files + partial.files, failures: partial.failures) }
        return .init(files: files, failures: [error.localizedDescription])
    }
}

/// New generated content is private from its first byte, including under an ACL-inheriting parent.
/// Final files also remain owner-only; the user can explicitly share the finished result afterwards.
enum FileSafety {
    /// Enforce the byte budget before allocation and again while reading a potentially growing file.
    static func read(_ source: URL, limit: Int) throws -> Data {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ToolError(L("Choose a regular local file.")) }
        guard info.st_size >= 0, info.st_size <= limit else { throw ToolError(L("This file exceeds the safe reading limit.")) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            guard count <= limit - result.count else { throw ToolError(L("This file exceeds the safe reading limit.")) }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    static func privateDirectory(beside target: URL) throws -> URL {
        let root = target.deletingLastPathComponent().appendingPathComponent(".swivel-" + UUID().uuidString)
        guard mkdir(root.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try makePrivate(root, directory: true) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        TemporaryItems.register(root)
        return root
    }

    static func makePrivate(_ url: URL, directory: Bool = false, preserveExecutable: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw ToolError(L("The output changed while it was being saved."))
        }
        guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let mode: mode_t = directory ? 0o700 : 0o600 | (preserveExecutable ? info.st_mode & 0o100 : 0)
        guard fchmod(fd, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Callers can inject a short/failed write in tests without changing process-wide limits.
    static func write(_ data: Data, to url: URL,
                      writer: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let amount = writer(fd, buffer.baseAddress!.advanced(by: offset), min(1_048_576, buffer.count - offset))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Capture one regular file through a held descriptor. Verification and extraction use this same snapshot.
    static func snapshot(_ source: URL, to target: URL, reserve: Int64) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ToolError(L("Choose a regular local file.")) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        let key = "com.apple.quarantine"
        let size = fgetxattr(input, key, nil, 0, 0, 0)
        if size < 0, errno != ENOATTR && errno != ENOTSUP { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if size > 0 {
            var value = [UInt8](repeating: 0, count: size)
            guard fgetxattr(input, key, &value, size, 0, 0) == size,
                  fsetxattr(output, key, value, size, 0, 0) == 0 else {
                throw ToolError(L("Couldn't mark the extracted files as downloaded."))
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            var space = statfs()
            guard fstatfs(output, &space) == 0, Int64(space.f_bavail) * Int64(space.f_bsize) > reserve + Int64(buffer.count) else {
                throw ToolError(L("Not enough free disk space to extract."))
            }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { throw ToolError(L("The source changed while it was being read. Try again.")) }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let n = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
        }
        var after = stat()
        guard fstat(input, &after) == 0, total == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ToolError(L("The source changed while it was being read. Try again."))
        }

    }
}
