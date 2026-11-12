import Darwin
import Foundation
import XCTest
@testable import ChengWen

final class StorageStressTests: XCTestCase {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-storage-stress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }
    private func job(_ id: String, state: String = "queued") -> [String: Any] {
        ["id": id, "state": state, "track": ["id": "synthetic-song", "title": "Synthetic title", "source": "netease"], "directory": "/tmp", "format": "mp3"]
    }
    func testAtomicPublicationRejectsNonRegularInputsWithoutMovingThem() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory"), fifo = root.appendingPathComponent("fifo"), link = root.appendingPathComponent("link"), bytes = root.appendingPathComponent("bytes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try Data("synthetic original".utf8).write(to: bytes)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bytes)
        for input in [directory, fifo, link] {
            XCTAssertThrowsError(try NativeMusicEngine.publish(input, in: root, name: "invalid-" + input.lastPathComponent, ext: "wav"))
            var info = stat()
            XCTAssertEqual(lstat(input.path, &info), 0, "An invalid input must be left untouched")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid-" + input.lastPathComponent + ".wav").path))
        }
        XCTAssertEqual(try String(contentsOf: bytes), "synthetic original")
    }
    func testCompatibilityFIFOInputIsRejectedWithoutWaitingForAWriter() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo"), target = root.appendingPathComponent("target.wav")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ready.signal()
            do {
                _ = try NativeMusicEngine.copyForPublication(fifo, to: target)
                XCTFail("An unexpected FIFO cannot be published")
            } catch { }
            finished.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        let promptlyRejected = finished.wait(timeout: .now() + 1) == .success
        if !promptlyRejected {
            // Release a buggy blocking open so a failing regression cannot
            // leave a permanent thread behind or hang the entire test run.
            let unblock = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if unblock >= 0 { close(unblock) }
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }
        XCTAssertTrue(promptlyRejected, "Opening an unexpected FIFO must not wait for another process")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testHistoryRootSymlinkCannotReadOrModifyAnExternalHistory() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let original = try JSONSerialization.data(withJSONObject: [job("external")])
        try original.write(to: real.appendingPathComponent("history.json"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = NativeHistoryStore(root: alias), loaded = store.load()
        XCTAssertTrue(loaded.jobs.isEmpty)
        XCTAssertNotNil(loaded.warning)
        XCTAssertTrue(store.writesBlocked)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("history.json")), original)
    }
    func testSixtyFourConcurrentSameNamePublicationsPreserveEveryPayloadAndExistingFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("same.wav")
        try Data("keep existing audio".utf8).write(to: existing)
        let count = 64
        let sources = try (0..<count).map { index -> URL in
            let path = root.appendingPathComponent("stage-\(index)")
            try Data(repeating: UInt8(index), count: 16384).write(to: path)
            return path
        }
        let paths = try await withThrowingTaskGroup(of: URL.self) { group -> [URL] in
            for source in sources {
                group.addTask { try NativeMusicEngine.publish(source, in: root, name: "same", ext: "wav") }
            }
            var paths = [URL]()
            for try await path in group { paths.append(path) }
            return paths
        }
        XCTAssertEqual(paths.count, count); XCTAssertEqual(Set(paths).count, count)
        var seen = Set<UInt8>()
        for path in paths {
            let data = try Data(contentsOf: path), byte = try XCTUnwrap(data.first)
            XCTAssertEqual(data, Data(repeating: byte, count: 16384)); seen.insert(byte)
        }
        XCTAssertEqual(seen, Set((0..<count).map(UInt8.init)))
        XCTAssertEqual(try String(contentsOf: existing), "keep existing audio")
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    func testSixteenCompatibilityWritersCompetingForOneTargetHaveExactlyOneWinner() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("contested.wav"), count = 16
        let sources = try (0..<count).map { index -> URL in
            let path = root.appendingPathComponent("source-\(index)")
            try Data(repeating: UInt8(index), count: 131072).write(to: path)
            return path
        }
        let winners = try await withThrowingTaskGroup(of: Int?.self) { group -> [Int] in
            for (index, source) in sources.enumerated() {
                group.addTask { try NativeMusicEngine.copyForPublication(source, to: target) ? index : nil }
            }
            var winners = [Int]()
            for try await winner in group { if let winner = winner { winners.append(winner) } }
            return winners
        }
        XCTAssertEqual(winners.count, 1)
        let winner = try XCTUnwrap(winners.first)
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: UInt8(winner), count: 131072))
        for (index, source) in sources.enumerated() {
            if index == winner { XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)) }
            else { XCTAssertEqual(try Data(contentsOf: source), Data(repeating: UInt8(index), count: 131072)) }
        }
    }
    func testFiveThousandDuplicateLegacyTaskIDsRepairAndSurviveThreeSaveReloadCycles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let count = NativeHistoryStore.maximumRecords
        let input = try JSONSerialization.data(withJSONObject: (0..<count).map { _ in job("duplicate") })
        try input.write(to: root.appendingPathComponent("history.json"))
        let store = NativeHistoryStore(root: root)
        let loaded = store.load()
        XCTAssertEqual(loaded.jobs.count, count)
        XCTAssertEqual(Set(loaded.jobs.map(\.id)).count, count)
        XCTAssertTrue(loaded.jobs.allSatisfy { $0.state == "interrupted" })
        XCTAssertNotNil(loaded.warning)
        for _ in 0..<3 {
            try store.save(loaded.jobs)
            let restored = store.load()
            XCTAssertNil(restored.warning)
            XCTAssertEqual(restored.jobs.map(\.id), loaded.jobs.map(\.id))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".history-write-") })
    }
    func testThirtyTwoRepeatedCorruptRecoveriesPreserveEveryOriginalAndPrivatePermissions() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var originals = Set<Data>()
        for index in 0..<32 {
            let bytes = Data("{synthetic corrupt history \(index)".utf8)
            originals.insert(bytes)
            try bytes.write(to: root.appendingPathComponent("history.json"))
            let store = NativeHistoryStore(root: root), loaded = store.load()
            XCTAssertTrue(loaded.jobs.isEmpty); XCTAssertNotNil(loaded.warning); XCTAssertFalse(store.writesBlocked)
            try store.save([])
        }
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("history-recovery-") }
        XCTAssertEqual(backups.count, 32)
        XCTAssertEqual(try Set(backups.map { try Data(contentsOf: $0) }), originals)
        for path in backups {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
