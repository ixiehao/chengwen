import Foundation
import Network
import XCTest
@testable import ChengWen

private final class SoakHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChengWen.NetworkSoak")
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Error>?
    private var connections: [NWConnection] = []
    private var seen: [String] = []
    private var port: UInt16 = 0
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); waiting = continuation; lock.unlock()
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    self.lock.lock(); self.port = self.listener.port!.rawValue
                    let waiting = self.waiting; self.waiting = nil; self.lock.unlock(); waiting?.resume()
                } else if case .failed(let error) = state {
                    self.lock.lock(); let waiting = self.waiting; self.waiting = nil; self.lock.unlock(); waiting?.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { connection in
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue); self.receive(connection, Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { bytes, _, complete, error in
            var request = prefix; request.append(bytes ?? Data())
            if request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 8192, !complete, error == nil {
                self.receive(connection, request); return
            }
            let text = String(decoding: request, as: UTF8.self)
            self.lock.lock(); self.seen.append(text); let port = self.port; self.lock.unlock()
            if text.hasPrefix("GET /redirect ") || text.hasPrefix("GET /cross ") || text.hasPrefix("GET /credentials ") {
                let location = text.hasPrefix("GET /credentials ") ? "http://synthetic:password@127.0.0.1:\(port)/slow" : text.hasPrefix("GET /cross ") ? "http://localhost:\(port)/slow" : "/slow"
                connection.send(content: Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let cut = text.hasPrefix("GET /cut ")
            let head = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: head, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                if cut {
                    connection.send(content: Data(repeating: 1, count: 1024), completion: .contentProcessed { _ in connection.cancel() })
                } else { self.send(connection, chunk: 0) }
            })
        }
    }
    private func send(_ connection: NWConnection, chunk: Int) {
        guard chunk < 16 else { connection.cancel(); return }
        connection.send(content: Data(repeating: 3, count: 4096), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.005) { self.send(connection, chunk: chunk + 1) }
        })
    }
    func url(_ path: String) -> URL { lock.lock(); defer { lock.unlock() }; return URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    func stop() { listener.cancel(); lock.lock(); let active = connections; connections = []; lock.unlock(); active.forEach { $0.cancel() } }
}
private final class WeakTransferBox: @unchecked Sendable {
    weak var value: NativeAudioTransfer?
    init(_ value: NativeAudioTransfer) { self.value = value }
}

final class NetworkSoakTests: XCTestCase {
    func testThirtyTwoSlowRedirectedPreviewsStayBoundedAndNeverSendCredentials() async throws {
        let server = try SoakHTTPServer(); try await server.start(); defer { server.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let result = try await NativeAudioTransfer(cap: 1024).run(url: server.url("redirect"), headers: ["Cookie": "synthetic-secret", "Authorization": "synthetic-secret"])
                    XCTAssertEqual(result.bytes, 1024); XCTAssertEqual(result.sample.count, 1024)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(server.requests.count, 64)
        XCTAssertFalse(server.requests.contains { $0.contains("synthetic-secret") })
    }
    func testTwentyRepeatedTruncatedResponsesNeverFinishAsWholeObject() async throws {
        let server = try SoakHTTPServer(); try await server.start(); defer { server.stop() }
        for _ in 0..<20 {
            do { _ = try await NativeAudioTransfer().run(url: server.url("cut"), headers: [:]); XCTFail("Truncated object accepted") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        XCTAssertEqual(server.requests.count, 20)
    }
    func testThirtyTwoInFlightCancellationsFinishAndReleaseTheirStreams() async throws {
        let server = try SoakHTTPServer(); try await server.start(); defer { server.stop() }
        let started = Date()
        let boxes = try await withThrowingTaskGroup(of: WeakTransferBox.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let transfer = NativeAudioTransfer()
                    let box = WeakTransferBox(transfer)
                    let work = Task { try await transfer.run(url: server.url("slow"), headers: [:]) }
                    try await Task.sleep(nanoseconds: 12_000_000); work.cancel()
                    do { _ = try await work.value; XCTFail("Slow request completed before cancellation") }
                    catch is CancellationError {} catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
                    return box
                }
            }
            var values: [WeakTransferBox] = []
            for try await value in group { values.append(value) }
            return values
        }
        let deadline = Date().addingTimeInterval(2)
        while boxes.contains(where: { $0.value != nil }), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(boxes.filter { $0.value != nil }.count, 0, "Completed/cancelled URLSession cycles retained streams")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testAPICrossHostRedirectRefusesToForwardSyntheticSession() async throws {
        let server = try SoakHTTPServer(); try await server.start(); defer { server.stop() }
        for _ in 0..<16 {
            do { _ = try await NativeHTTP.data(server.url("cross"), headers: ["Cookie": "synthetic-api-only"]); XCTFail("API followed cross-host redirect") }
            catch let error as EngineFailure { XCTAssertEqual(error.code, "source_unavailable") }
        }
        XCTAssertEqual(server.requests.count, 16)
        XCTAssertTrue(server.requests.allSatisfy { $0.hasPrefix("GET /cross ") })
    }
    func testAPISameOriginCredentialRedirectIsRejectedBeforeFollowing() async throws {
        let server = try SoakHTTPServer(); try await server.start(); defer { server.stop() }
        do {
            _ = try await NativeHTTP.data(server.url("credentials"), headers: ["Cookie": "synthetic-api-only"])
            XCTFail("API followed a credential-bearing redirect")
        } catch {}
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(server.requests.allSatisfy { $0.hasPrefix("GET /credentials ") })
    }
}
