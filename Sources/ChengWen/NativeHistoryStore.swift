import Foundation
import CoreFoundation
import Darwin

/// Versioned download history. Recovery never overwrites a file that could
/// not be read or safely preserved, and committed records are private.
final class NativeHistoryStore {
    static let schema = 1
    static let maximumBytes = 20_000_000
    static let maximumRecords = 5_000
    struct Loaded {
        let jobs: [DownloadJob]
        let warning: String?
    }
    enum Failure: Error { case corrupt, futureVersion, oversized, unsafeFile, blocked }
    let root: URL
    private(set) var writesBlocked = false
    private let moveForRecovery: (URL, URL) throws -> Void
    private let atomicWriter: (Data, URL) throws -> Void
    private var file: URL { root.appendingPathComponent("history.json") }

    // Fault-injection seams exercise recovery/write failures without changing
    // permissions or reading a user's actual Application Support directory.
    init(root: URL, moveForRecovery: ((URL, URL) throws -> Void)? = nil,
         atomicWriter: ((Data, URL) throws -> Void)? = nil) {
        self.root = root
        self.moveForRecovery = moveForRecovery ?? { try FileManager.default.moveItem(at: $0, to: $1) }
        self.atomicWriter = atomicWriter ?? Self.writePrivateAtomically
    }

    func load() -> Loaded {
        writesBlocked = false
        let data: Data
        do {
            guard let bytes = try readBounded() else { return Loaded(jobs: [], warning: nil) }
            data = bytes
        } catch Failure.oversized {
            return preserveInvalidHistory()
        } catch {
            writesBlocked = true
            return Loaded(jobs: [], warning: "下载记录暂时无法读取，已暂停保存以保护原记录。请检查目录权限后重新启动。")
        }
        do {
            let records = try decode(data)
            var seen = Set<String>(), jobs = [DownloadJob](), repaired = false
            for record in records {
                guard var job = DownloadJob(history: record) else { throw Failure.corrupt }
                if record["id"] as? String != job.id { repaired = true }
                if !seen.insert(job.id).inserted {
                    repeat { job.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
                    while !seen.insert(job.id).inserted
                    repaired = true
                }
                jobs.append(job)
            }
            return Loaded(jobs: jobs, warning: repaired ? "已修复下载记录中的空任务标识或重复标识，原有任务已保留。" : nil)
        } catch {
            return preserveInvalidHistory()
        }
    }

    func save(_ jobs: [DownloadJob]) throws {
        guard !writesBlocked else { throw Failure.blocked }
        // An old, slow task can outlive hundreds of newer completed tasks.
        // Keep unfinished tasks as well as the newest 500 finished records, while
        // preserving insertion order for history display and FIFO scheduling.
        var finished = 0
        let retained = jobs.reversed().filter { job in
            if job.active || job.state == "interrupted" { return true }
            finished += 1
            return finished <= 500
        }.reversed()
        guard retained.count <= Self.maximumRecords else { throw Failure.oversized }
        let data = try JSONSerialization.data(withJSONObject: ["schema": Self.schema, "jobs": retained.map(\.history)], options: [.sortedKeys, .prettyPrinted])
        guard data.count <= Self.maximumBytes else { throw Failure.oversized }
        try prepareDirectory()
        try atomicWriter(data, file)
    }

    private func decode(_ data: Data) throws -> [[String: Any]] {
        let document = try JSONSerialization.jsonObject(with: data)
        let values: [Any]
        if let legacy = document as? [Any] { values = legacy }
        else {
            guard let object = document as? [String: Any], let number = object["schema"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { throw Failure.corrupt }
            guard number.doubleValue <= Double(Self.schema) else { throw Failure.futureVersion }
            guard number.intValue == Self.schema, let records = object["jobs"] as? [Any] else { throw Failure.corrupt }
            values = records
        }
        guard values.count <= Self.maximumRecords else { throw Failure.oversized }
        guard let records = values as? [[String: Any]] else { throw Failure.corrupt }
        return records
    }

    private func readBounded() throws -> Data? {
        // Match the save-side root rule before following history.json. A
        // symlink at the root must not expose an unrelated history in the UI.
        var directory = stat()
        if lstat(root.path, &directory) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard directory.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        guard info.st_size <= Self.maximumBytes else { throw Failure.oversized }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw Failure.oversized }
        return data
    }

    private func preserveInvalidHistory() -> Loaded {
        do {
            try prepareDirectory()
            let backup = root.appendingPathComponent("history-recovery-\(UUID().uuidString).json")
            try moveForRecovery(file, backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return Loaded(jobs: [], warning: "下载记录格式损坏或版本较新，原文件已备份保留。当前使用空列表，不会删除已下载的音频。")
        } catch {
            writesBlocked = true
            return Loaded(jobs: [], warning: "下载记录暂时无法恢复，原文件尚未安全备份，已暂停保存。请检查目录权限后重新启动。")
        }
    }

    private func prepareDirectory() throws {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if info.st_mode & S_IFMT != S_IFDIR { throw Failure.unsafeFile }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private static func writePrivateAtomically(_ data: Data, _ destination: URL) throws {
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".history-write-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var committed = false
        defer {
            _ = close(descriptor)
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        committed = true
    }
}
