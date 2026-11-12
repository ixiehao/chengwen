import Darwin
import Foundation
import XCTest
@testable import ChengWen

/// By default these cases use the system temporary volume. Release checks can
/// point CHENGWEN_PUBLISH_TEST_ROOT / CHENGWEN_PUBLISH_SECOND_VOLUME at self-owned
/// APFS and ExFAT images; no user music or account data is needed.
final class NativePublishCompatibilityTests: XCTestCase {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["CHENGWEN_PUBLISH_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("chengwen-publish-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func staged(_ data: Data, in root: URL, name: String = "output") throws -> URL {
        let directory = root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(name)
        try data.write(to: source)
        return source
    }
    func testPortableNameRemovesFATReservedPunctuationBeforePublishing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let portable = NativeMusicEngine.safeName("A?B*C\"D<E>F|G/H\\I:J\n")
        XCTAssertEqual(portable, "A_B_C_D_E_F_G_H_I_J_")
        XCTAssertFalse(portable.contains { "*?\"<>|/\\:".contains($0) })
        let source = try staged(Data("portable name".utf8), in: root)
        let target = try NativeMusicEngine.publish(source, in: root, name: portable, ext: "wav")
        XCTAssertEqual(try String(contentsOf: target), "portable name")
    }
    func testAtomicPublishMovesVerifiedFileAndStageCleanupKeepsResult() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x5A, count: 131072)
        let source = try staged(bytes, in: root)
        let target = try NativeMusicEngine.publish(source, in: root, name: "合成音频", ext: "wav")
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: target), bytes, "Removing the private staging directory cannot remove committed audio")
    }
    func testRegularFileAndDirectoryCollisionsUseNextNameWithoutReplacingAnything() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("track.mp3")
        let directory = root.appendingPathComponent("track (2).mp3", isDirectory: true)
        try Data("old".utf8).write(to: existing)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = try staged(Data("new".utf8), in: root)
        let target = try NativeMusicEngine.publish(source, in: root, name: "track", ext: "mp3")
        XCTAssertEqual(target.lastPathComponent, "track (3).mp3")
        XCTAssertEqual(try String(contentsOf: existing), "old")
        XCTAssertEqual(try String(contentsOf: target), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
    func testExistingAndDanglingSymlinksAreNeitherFollowedNorReplaced() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capabilities = try root.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey])
        guard capabilities.volumeSupportsSymbolicLinks == true else {
            throw XCTSkip("This filesystem does not support creating symlinks; run this case on APFS as well")
        }
        let old = root.appendingPathComponent("existing")
        try Data("old".utf8).write(to: old)
        let first = root.appendingPathComponent("track.mp3"), dangling = root.appendingPathComponent("track (2).mp3")
        let absent = root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: old)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: absent)
        let source = try staged(Data("new".utf8), in: root)
        let target = try NativeMusicEngine.publish(source, in: root, name: "track", ext: "mp3")
        XCTAssertEqual(target.lastPathComponent, "track (3).mp3")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.path), old.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), absent.path)
        XCTAssertEqual(try String(contentsOf: old), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        XCTAssertEqual(try String(contentsOf: target), "new")
        let nextSource = try staged(Data("another".utf8), in: root, name: "another")
        XCTAssertFalse(try NativeMusicEngine.copyForPublication(nextSource, to: first))
        XCTAssertFalse(try NativeMusicEngine.copyForPublication(nextSource, to: dangling))
        XCTAssertEqual(try String(contentsOf: old), "old")
        XCTAssertEqual(try String(contentsOf: nextSource), "another")
    }
    func testConcurrentPublishersCommitDistinctCompleteFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = try (0..<12).map { try staged(Data("synthetic-\($0)".utf8), in: root, name: "output-\($0)") }
        let paths = try await withThrowingTaskGroup(of: URL.self) { group -> [URL] in
            for source in sources {
                group.addTask { try NativeMusicEngine.publish(source, in: root, name: "same name", ext: "wav") }
            }
            var paths: [URL] = []
            for try await path in group { paths.append(path) }
            return paths
        }
        XCTAssertEqual(Set(paths).count, 12)
        XCTAssertEqual(try Set(paths.map { try String(contentsOf: $0) }), Set((0..<12).map { "synthetic-\($0)" }))
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    func testCancelledTaskCannotCommitOrRemoveStagedFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("cancelled".utf8), in: root)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativeMusicEngine.publish(source, in: root, name: "cancelled", ext: "wav")
        }
        do { _ = try await work.value; XCTFail("Cancellation before the commit must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: source), "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.wav").path))
    }
    func testCancellationAfterCommitDoesNotTurnSavedAudioIntoFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("committed".utf8), in: root)
        let work = Task {
            let path = try NativeMusicEngine.publish(source, in: root, name: "committed", ext: "wav")
            withUnsafeCurrentTask { $0?.cancel() }
            return path
        }
        let target = try await work.value
        XCTAssertTrue(work.isCancelled)
        XCTAssertEqual(try String(contentsOf: target), "committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testTooManyNamesLeavesStagedFileUntouched() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1000 {
            let name = "track" + (index == 0 ? "" : " (\(index + 1))") + ".wav"
            try Data().write(to: root.appendingPathComponent(name))
        }
        let source = try staged(Data("staged".utf8), in: root)
        XCTAssertThrowsError(try NativeMusicEngine.publish(source, in: root, name: "track", ext: "wav")) { error in
            XCTAssertTrue((error as? EngineFailure)?.reason.contains("同名文件过多") == true)
        }
        XCTAssertEqual(try String(contentsOf: source), "staged")
    }
    func testPermissionDiskSpaceAndUnsupportedFailuresHaveDistinctSolutions() {
        for status in [EACCES, EPERM, EROFS, ENOSPC, EDQUOT, ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL, EXDEV, ENOENT, ENOTDIR, EIO, ENXIO] {
            let failure = NativeMusicEngine.publishFailure(status)
            XCTAssertEqual(failure.code, "filesystem")
            XCTAssertEqual(failure.technical, "POSIX errno \(status)")
            XCTAssertFalse(failure.solution.isEmpty)
        }
        XCTAssertTrue(NativeMusicEngine.publishFailure(EACCES).reason.contains("权限"))
        XCTAssertTrue(NativeMusicEngine.publishFailure(ENOSPC).reason.contains("空间"))
        XCTAssertTrue(NativeMusicEngine.publishFailure(ENOTSUP).reason.contains("不支持"))
        XCTAssertNotEqual(NativeMusicEngine.publishFailure(EACCES).solution, NativeMusicEngine.publishFailure(ENOSPC).solution)
        XCTAssertNotEqual(NativeMusicEngine.publishFailure(ENOTSUP).solution, NativeMusicEngine.publishFailure(EACCES).solution)
    }
    func testInvalidExtensionAndMissingSourceLeaveDestinationUntouched() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("verified".utf8), in: root)
        for ext in ["", "exe", "../escape", "mp3/escape"] {
            XCTAssertThrowsError(try NativeMusicEngine.publish(source, in: root, name: "invalid", ext: ext)) { error in
                XCTAssertEqual((error as? EngineFailure)?.code, "invalid_request")
            }
        }
        XCTAssertEqual(try String(contentsOf: source), "verified")
        let absent = source.deletingLastPathComponent().appendingPathComponent("absent")
        XCTAssertThrowsError(try NativeMusicEngine.publish(absent, in: root, name: "absent", ext: "wav")) { error in
            XCTAssertEqual((error as? EngineFailure)?.technical, "POSIX errno \(ENOENT)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".staging"])
    }
    func testUnwritableDirectoryPreservesSourceAndReportsPermissions() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial cannot be reproduced as root") }
        let root = try root()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        guard try root.resourceValues(forKeys: [.volumeSupportsAccessPermissionsKey]).volumeSupportsAccessPermissions == true else {
            throw XCTSkip("This filesystem does not enforce POSIX directory permissions")
        }
        let source = try staged(Data("retained".utf8), in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try NativeMusicEngine.publish(source, in: root, name: "denied", ext: "wav")) { error in
            let failure = error as? EngineFailure
            XCTAssertEqual(failure?.code, "filesystem")
            XCTAssertTrue(failure?.reason.contains("权限") == true)
        }
        XCTAssertEqual(try String(contentsOf: source), "retained")
    }
    func testVolumeWithoutExclusiveRenameUsesSafeCopyCompatibility() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        guard try root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming == false else {
            throw XCTSkip("This volume supports exclusive renaming; run this compatibility case on a self-owned ExFAT image")
        }
        let existing = root.appendingPathComponent("compat.wav")
        try Data("old".utf8).write(to: existing)
        let source = try staged(Data("compatibility copy".utf8), in: root)
        let target = try NativeMusicEngine.publish(source, in: root, name: "compat", ext: "wav")
        XCTAssertEqual(target.lastPathComponent, "compat (2).wav")
        XCTAssertEqual(try String(contentsOf: target), "compatibility copy")
        XCTAssertEqual(try String(contentsOf: existing), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testCompatibilityPartialWritesAreCompletedBeforeSuccessfulSync() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x35, count: 131072)
        let source = try staged(bytes, in: root), target = root.appendingPathComponent("copied.wav")
        var io = NativePublishIO(), synced = false
        io.write = { fd, pointer, count in Darwin.write(fd, pointer, min(count, 1024)) }
        io.synchronize = { fd in synced = true; return Darwin.fsync(fd) }
        XCTAssertTrue(try NativeMusicEngine.copyForPublication(source, to: target, io: io))
        XCTAssertTrue(synced)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testCompatibilityWriteFailureRemovesOnlyOwnPartialFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 1, count: 131072)
        let source = try staged(bytes, in: root), target = root.appendingPathComponent("failed.wav")
        var io = NativePublishIO(), calls = 0
        io.write = { fd, pointer, count in
            calls += 1
            if calls == 1 { return Darwin.write(fd, pointer, min(count, 128)) }
            errno = ENOSPC; return -1
        }
        XCTAssertThrowsError(try NativeMusicEngine.copyForPublication(source, to: target, io: io)) { error in
            XCTAssertTrue((error as? EngineFailure)?.reason.contains("空间") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testCompatibilitySyncFailureDoesNotCommitOrLoseSource() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("retained".utf8), in: root), target = root.appendingPathComponent("unsynced.wav")
        var io = NativePublishIO()
        io.synchronize = { _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try NativeMusicEngine.copyForPublication(source, to: target, io: io)) { error in
            XCTAssertEqual((error as? EngineFailure)?.technical, "POSIX errno \(EIO)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: source), "retained")
    }
    func testCancellationDuringCompatibilityCopyCleansPartialAndKeepsSource() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 2, count: 131072)
        let source = try staged(bytes, in: root), target = root.appendingPathComponent("cancelled-copy.wav")
        let work = Task {
            var io = NativePublishIO()
            io.write = { fd, pointer, count in
                let amount = Darwin.write(fd, pointer, count)
                withUnsafeCurrentTask { $0?.cancel() }
                return amount
            }
            return try NativeMusicEngine.copyForPublication(source, to: target, io: io)
        }
        do { _ = try await work.value; XCTFail("A cancelled unfinished copy cannot succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testCancellationAtSuccessfulSyncKeepsCommittedCompatibilityAudio() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("committed".utf8), in: root), target = root.appendingPathComponent("synced.wav")
        let work = Task {
            var io = NativePublishIO()
            io.synchronize = { fd in
                let status = Darwin.fsync(fd)
                withUnsafeCurrentTask { $0?.cancel() }
                return status
            }
            return try NativeMusicEngine.copyForPublication(source, to: target, io: io)
        }
        let saved = try await work.value
        XCTAssertTrue(saved)
        XCTAssertTrue(work.isCancelled)
        XCTAssertEqual(try String(contentsOf: target), "committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testCompatibilityCleanupPreservesAPathReplacedByAnotherWriter() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try staged(Data("ours".utf8), in: root), target = root.appendingPathComponent("replacement.wav")
        var io = NativePublishIO()
        io.afterCreate = {
            XCTAssertEqual(unlink(target.path), 0)
            try Data("other writer".utf8).write(to: target)
        }
        io.write = { _, _, _ in errno = ENOSPC; return -1 }
        XCTAssertThrowsError(try NativeMusicEngine.copyForPublication(source, to: target, io: io))
        XCTAssertEqual(try String(contentsOf: target), "other writer")
        XCTAssertEqual(try String(contentsOf: source), "ours")
    }
    func testCompatibilityCannotCommitAReplacedPathEvenWhenIOSucceeds() throws {
        for replaceDuringSync in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let source = try staged(Data("ours".utf8), in: root), target = root.appendingPathComponent("replacement.wav")
            let replace = {
                XCTAssertEqual(unlink(target.path), 0)
                try Data("other writer".utf8).write(to: target)
            }
            var io = NativePublishIO()
            if replaceDuringSync {
                io.synchronize = { fd in
                    let status = Darwin.fsync(fd)
                    do { try replace() } catch { XCTFail("Synthetic replacement failed: \(error)") }
                    return status
                }
            } else { io.afterCreate = replace }
            XCTAssertThrowsError(try NativeMusicEngine.copyForPublication(source, to: target, io: io)) { error in
                XCTAssertTrue((error as? EngineFailure)?.reason.contains("替换") == true)
            }
            XCTAssertEqual(try String(contentsOf: target), "other writer")
            XCTAssertEqual(try String(contentsOf: source), "ours")
        }
    }
    func testCrossVolumeMoveFailsWithoutCopyingOrReplacing() throws {
        guard let second = ProcessInfo.processInfo.environment["CHENGWEN_PUBLISH_SECOND_VOLUME"] else {
            throw XCTSkip("Set a second self-owned filesystem to verify EXDEV without accessing user volumes")
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = URL(fileURLWithPath: second).appendingPathComponent("chengwen-cross-volume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = try staged(Data("never copy".utf8), in: root)
        XCTAssertThrowsError(try NativeMusicEngine.publish(source, in: destination, name: "cross-volume", ext: "wav")) { error in
            XCTAssertEqual((error as? EngineFailure)?.technical, "POSIX errno \(EXDEV)")
        }
        XCTAssertEqual(try String(contentsOf: source), "never copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
}
