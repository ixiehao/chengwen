import Foundation
import Network
import XCTest
@testable import ChengWen

private final class BoundaryProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int64] = []
    func append(_ count: Int64) { lock.lock(); counts.append(count); lock.unlock() }
    var maximum: Int64 { lock.lock(); defer { lock.unlock() }; return counts.max() ?? 0 }
}

/// A self-owned loopback HTTP server. Chunked delivery can state an object
/// range independently of the actual body, without contacting a platform.
private final class BoundaryHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChengWen.HTTPBoundaryFixture")
    private let lock = NSLock()
    private let chunks: [Data]
    private let status: Int
    private let headers: [String: String]
    private let chunked: Bool
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var port: UInt16 = 0

    init(body: Data, status: Int = 200, headers: [String: String] = [:], chunked: Bool = false, firstChunk: Int? = nil) throws {
        self.status = status; self.headers = headers; self.chunked = chunked
        if let firstChunk = firstChunk, firstChunk < body.count {
            chunks = [Data(body.prefix(firstChunk)), Data(body.dropFirst(firstChunk))]
        } else { chunks = [body] }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); self.continuation = continuation; lock.unlock()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.lock.lock(); self.port = self.listener.port!.rawValue
                    let waiting = self.continuation; self.continuation = nil; self.lock.unlock()
                    waiting?.resume()
                case .failed(let error):
                    self.lock.lock(); let waiting = self.continuation; self.continuation = nil; self.lock.unlock()
                    waiting?.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var request = accumulated; request.append(data ?? Data())
            if request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 8192, !complete, error == nil {
                self.receive(connection, accumulated: request); return
            }
            var fields = self.headers
            fields["Content-Type"] = "audio/wav"; fields["Connection"] = "close"
            if self.chunked { fields["Transfer-Encoding"] = "chunked" }
            else if fields["Content-Length"] == nil { fields["Content-Length"] = String(self.chunks.reduce(0) { $0 + $1.count }) }
            let lines = fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            let head = Data("HTTP/1.1 \(self.status) OK\r\n\(lines)\r\n\r\n".utf8)
            connection.send(content: head, completion: .contentProcessed { error in
                guard error == nil else { return }
                self.send(connection, index: 0)
            })
        }
    }

    private func send(_ connection: NWConnection, index: Int) {
        guard index < chunks.count else {
            connection.send(content: chunked ? Data("0\r\n\r\n".utf8) : Data(), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = chunks[index]
        let framed = chunked ? Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n".utf8) : body
        connection.send(content: framed, completion: .contentProcessed { error in
            guard error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + 0.05) { self.send(connection, index: index + 1) }
        })
    }

    func stop() {
        listener.cancel(); lock.lock(); let active = connections; connections = []; lock.unlock()
        active.forEach { $0.cancel() }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/audio")! }
}

final class NativeHTTPBoundaryTests: XCTestCase {
    private func rejected(_ server: BoundaryHTTPServer, code: String = "audio_incomplete") async throws {
        try await server.start(); defer { server.stop() }
        do { _ = try await NativeAudioTransfer().run(url: server.url, headers: [:]); XCTFail("Incomplete response accepted as a complete object") }
        catch let failure as EngineFailure { XCTAssertEqual(failure.code, code) }
    }

    func testComplete206ObjectIsAccepted() async throws {
        let body = Data(repeating: 1, count: 4096)
        let server = try BoundaryHTTPServer(body: body, status: 206, headers: ["Content-Range": "bytes 0-4095/4096"])
        try await server.start(); defer { server.stop() }
        let result = try await NativeAudioTransfer(maximumBytes: 4096).run(url: server.url, headers: [:])
        XCTAssertEqual(result.bytes, 4096); XCTAssertEqual(result.sample, body)
    }

    func testPartial206CannotPublishEvenWhenBodyIsAValidCompleteWAV() async throws {
        let body = NativeFixtureServer.wave()
        let server = try BoundaryHTTPServer(body: body, status: 206, headers: ["Content-Range": "bytes 0-\(body.count - 1)/\(body.count + 1000)"])
        try await server.start(); defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-partial-206-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await NativeMusicEngine.download(["title": "Self-owned range fixture", "artist": "Synthetic"], resolved: NativeResolvedAudio(url: server.url, expectedDuration: 3, container: "wav"), directory: root, format: "original", saveLyrics: false, event: { _, _ in })
            XCTFail("A partial HTTP object was published as a complete song")
        } catch let failure as EngineFailure { XCTAssertEqual(failure.code, "audio_incomplete") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testMissingMalformedUnknownAndOverflowing206RangesAreRejected() async throws {
        for range in [nil, "bytes 0-4095/*", "bytes 1-4096/4097", "items 0-4095/4096", "bytes 0-4096/4096", "bytes 0-9223372036854775808/9223372036854775809"] as [String?] {
            let headers = range.map { ["Content-Range": $0] } ?? [:]
            try await rejected(BoundaryHTTPServer(body: Data(repeating: 1, count: 4096), status: 206, headers: headers))
        }
    }

    func testComplete206RangeMustAgreeWithContentLength() async throws {
        try await rejected(BoundaryHTTPServer(body: Data(repeating: 1, count: 4096), status: 206, headers: ["Content-Range": "bytes 0-4095/4096", "Content-Length": "4000"]))
    }

    func testChunked206ActualBytesMustMatchItsClaimedWholeObject() async throws {
        try await rejected(BoundaryHTTPServer(body: Data(repeating: 1, count: 2048), status: 206, headers: ["Content-Range": "bytes 0-4095/4096"], chunked: true))
    }

    func testPreview206StillAcceptsItsBoundedSliceOfALargeObject() async throws {
        let body = Data(repeating: 1, count: 131072)
        let server = try BoundaryHTTPServer(body: body, status: 206, headers: ["Content-Range": "bytes 0-131071/1073741824"])
        try await server.start(); defer { server.stop() }
        let result = try await NativeAudioTransfer(cap: 131072).run(url: server.url, headers: [:])
        XCTAssertEqual(result.bytes, 131072)
    }

    func testPreviewCanStopWhenRangeIsIgnoredAndContentLengthExceedsTheLimit() async throws {
        let server = try BoundaryHTTPServer(body: Data(repeating: 1, count: 1024), headers: ["Content-Length": "1048576"])
        try await server.start(); defer { server.stop() }
        let result = try await NativeAudioTransfer(cap: 1024, maximumBytes: 4096).run(url: server.url, headers: [:])
        XCTAssertEqual(result.bytes, 1024)
    }

    func testChunkedSizeLimitIsCheckedBeforeWritingOrProgress() async throws {
        let server = try BoundaryHTTPServer(body: Data(repeating: 1, count: 5120), chunked: true, firstChunk: 4096)
        try await server.start(); defer { server.stop() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-byte-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let progress = BoundaryProgress()
        do {
            _ = try await NativeAudioTransfer(destination: path, maximumBytes: 4096, progress: { bytes, _ in progress.append(bytes) }).run(url: server.url, headers: [:])
            XCTFail("Oversized response succeeded")
        } catch let failure as EngineFailure { XCTAssertEqual(failure.code, "source_response") }
        XCTAssertLessThanOrEqual(try Data(contentsOf: path).count, 4096)
        XCTAssertGreaterThan(progress.maximum, 0)
        XCTAssertLessThanOrEqual(progress.maximum, 4096)
    }

    func testOversizedDeclaredObjectIsRejectedBeforeAnyBodyWrite() async throws {
        let server = try BoundaryHTTPServer(body: Data(repeating: 1, count: 4097))
        try await server.start(); defer { server.stop() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-length-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let progress = BoundaryProgress()
        do {
            _ = try await NativeAudioTransfer(destination: path, maximumBytes: 4096, progress: { bytes, _ in progress.append(bytes) }).run(url: server.url, headers: [:])
            XCTFail("Oversized Content-Length succeeded")
        } catch let failure as EngineFailure { XCTAssertEqual(failure.code, "source_response") }
        XCTAssertEqual(try Data(contentsOf: path).count, 0)
        XCTAssertEqual(progress.maximum, 0)
    }

    func testObjectExactlyAtTheLimitCompletes() async throws {
        let body = Data(repeating: 1, count: 4096), progress = BoundaryProgress()
        let server = try BoundaryHTTPServer(body: body)
        try await server.start(); defer { server.stop() }
        let result = try await NativeAudioTransfer(maximumBytes: 4096, progress: { bytes, _ in progress.append(bytes) }).run(url: server.url, headers: [:])
        XCTAssertEqual(result.bytes, 4096); XCTAssertEqual(progress.maximum, 4096)
    }
}
