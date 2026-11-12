import Foundation
import Network
import Darwin

/// Self-owned loopback fixture used by XCTest and installed-copy checks.
/// It deliberately ignores Range so the client's bounded reader is exercised.
final class NativeFixtureServer: @unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"ChengWen.LocalFixture")
    private let audio:Data
    private let lock=NSLock()
    private var connections:[NWConnection]=[]
    private var waiting:CheckedContinuation<Void,Error>?
    private(set) var port:UInt16=0
    init(audio:Data) throws {
        self.audio=audio
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        listener=try NWListener(using:parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            lock.lock();waiting=continuation;lock.unlock()
            listener.stateUpdateHandler={ state in
                switch state {
                case .ready:
                    self.lock.lock();self.port=self.listener.port!.rawValue;let waiting=self.waiting;self.waiting=nil;self.lock.unlock();waiting?.resume()
                case .failed(let error):
                    self.lock.lock();let waiting=self.waiting;self.waiting=nil;self.lock.unlock();waiting?.resume(throwing:error)
                default:break
                }
            }
            listener.newConnectionHandler={ connection in
                self.lock.lock();self.connections.append(connection);self.lock.unlock()
                connection.start(queue:self.queue);self.receive(connection,accumulated:Data())
            }
            listener.start(queue:queue)
        }
    }
    private func receive(_ connection:NWConnection,accumulated:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192){data,_,complete,error in
            var request=accumulated;request.append(data ?? Data())
            if request.range(of:Data("\r\n\r\n".utf8)) == nil && request.count<8192 && !complete && error==nil {self.receive(connection,accumulated:request);return}
            let text=String(data:request,encoding:.utf8) ?? ""
            let html=text.hasPrefix("GET /html ")
            let body=html ? Data("<html>not audio</html>".utf8) : self.audio
            let header="HTTP/1.1 200 OK\r\nContent-Type: \(html ? "text/html" : "audio/wav")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content:Data(header.utf8)+body,completion:.contentProcessed{_ in connection.cancel()})
        }
    }
    func stop(){listener.cancel();lock.lock();let active=connections;connections=[];lock.unlock();active.forEach{$0.cancel()}}
    func url(_ path:String="audio") -> URL {URL(string:"http://127.0.0.1:\(port)/\(path)")!}
    static func wave(seconds:Int=3) -> Data {
        let rate=44100,frames=rate*seconds,size=frames*2
        var data=Data("RIFF".utf8)
        func append<T:FixedWidthInteger>(_ value:T) {var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
        append(UInt32(size+36));data.append(Data("WAVEfmt ".utf8));append(UInt32(16));append(UInt16(1));append(UInt16(1));append(UInt32(rate));append(UInt32(rate*2));append(UInt16(2));append(UInt16(16));data.append(Data("data".utf8));append(UInt32(size))
        for index in 0..<frames {append(Int16(sin(Double(index)*2*Double.pi*440/Double(rate))*1000))}
        return data
    }
}

enum NativeEngineSmoke {
    static func run() async throws -> [String:Any] {
        let fixture=try NativeFixtureServer(audio:NativeFixtureServer.wave())
        try await fixture.start();defer{fixture.stop()}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-swift-smoke-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let resolved=NativeResolvedAudio(url:fixture.url(),expectedDuration:3,container:"wav")
        let probe=try await NativeMusicEngine.probe(resolved)
        guard (probe["sample_bytes"] as? Int64 ?? 0)==131072 else{throw EngineFailure(reason:"预下载边界检查失败。")}
        var formats=[String]()
        for format in ["original","mp3","m4a","flac","wav"] {
            let result=try await NativeMusicEngine.download(["id":"local","title":"Synthetic audio","artist":"ChengWen"],resolved:resolved,directory:root,format:format,saveLyrics:false,event:{_,_ in})
            guard let path=result["path"] as? String,FileManager.default.fileExists(atPath:path) else{throw EngineFailure(reason:"音频保存检查失败。")}
            formats.append(format)
        }
        let existing=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        guard existing.count==5,existing.allSatisfy({!$0.lastPathComponent.hasPrefix(".chengwen-")}) else{throw EngineFailure(reason:"同名保护或临时目录清理检查失败。")}
        var htmlRejected=false
        do {_=try await NativeMusicEngine.probe(NativeResolvedAudio(url:fixture.url("html")))} catch {htmlRejected=true}
        var shortRejected=false
        do {_=try await NativeMusicEngine.inspect(existing[0],expected:120)} catch {shortRejected=true}
        guard htmlRejected,shortRejected else{throw EngineFailure(reason:"音频校验检查失败。")}
        var info=utsname();uname(&info)
        let capacity=MemoryLayout.size(ofValue:info.machine)
        let architecture=withUnsafePointer(to:&info.machine){$0.withMemoryRebound(to:CChar.self,capacity:capacity){String(cString:$0)}}
        return ["passed":true,"implementation":"Swift","architecture":architecture,"no_python":true,"output_formats":formats,"bounded_preview":true,"html_rejected":true,"incomplete_rejected":true,"no_overwrite":true,"temporary_cleanup":true]
    }
}
