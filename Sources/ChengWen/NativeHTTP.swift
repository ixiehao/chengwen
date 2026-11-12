import Foundation
import Darwin

enum NativeHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 600
        return config
    }
    static func data(_ url: URL, headers: [String:String] = [:], method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard url.user==nil,url.password==nil,url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else {
            throw EngineFailure(reason: "平台未返回安全的 HTTPS 地址。", solution: "请重新搜索或更换来源。", code: "source_response")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: configuration(),delegate:NativeAPIRedirectGuard(origin:url),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (stream,response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw EngineFailure(reason: "平台响应无效。", code: "source_response") }
        guard (200..<300).contains(response.statusCode) else { throw status(response.statusCode) }
        var data=Data()
        for try await byte in stream {
            guard data.count<8_000_000 else {throw EngineFailure(reason:"平台响应过大，已停止读取。",code:"source_response")}
            data.append(byte)
        }
        return (data,response)
    }
    static func json(_ url: URL, headers: [String:String] = [:], method: String = "GET", body: Data? = nil) async throws -> [String:Any] {
        let (data,_) = try await self.data(url,headers:headers,method:method,body:body)
        guard let result = try? decodeObject(data) else {
            throw EngineFailure(reason: "平台没有返回有效的歌曲数据。", solution: "请稍后重试或更换来源。", code: "source_response")
        }
        return result
    }
    /// Kuwo's legacy search returns a quoted object literal, not JSON.
    /// Convert only string delimiters/literal constants; never execute scripts.
    static func decodeObject(_ data:Data) throws -> [String:Any] {
        if let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {return object}
        guard data.count<=8_000_000 else{throw NativeAudioTransfer.unavailable()}
        let input=[UInt8](data);var output=Data(),index=0,quote:UInt8?=nil,depth=0
        while index<input.count {
            let byte=input[index]
            if let delimiter=quote {
                if byte==delimiter {output.append(34);quote=nil}
                else if byte==92 {
                    index+=1;guard index<input.count else{throw NativeAudioTransfer.unavailable()}
                    let escaped=input[index]
                    if escaped==39 {output.append(39)}
                    else {output.append(92);output.append(escaped)}
                } else if byte==34 {output.append(contentsOf:[92,34])}
                else {output.append(byte)}
            } else if byte==39 || byte==34 {quote=byte;output.append(34)}
            else if (65...90).contains(byte) || (97...122).contains(byte) {
                let start=index
                while index<input.count && ((65...90).contains(input[index]) || (97...122).contains(input[index])) {index+=1}
                let token=String(bytes:input[start..<index],encoding:.ascii) ?? ""
                let values=["true":"true","false":"false","null":"null","True":"true","False":"false","None":"null"]
                guard let literal=values[token] else{throw NativeAudioTransfer.unavailable()}
                output.append(Data(literal.utf8));index-=1
            } else {
                if byte==123 || byte==91 {depth+=1;if depth>40{throw NativeAudioTransfer.unavailable()}}
                if byte==125 || byte==93 {depth-=1}
                output.append(byte)
            }
            index+=1
        }
        guard quote==nil,depth==0,let object=try JSONSerialization.jsonObject(with:output) as? [String:Any] else{throw NativeAudioTransfer.unavailable()}
        return object
    }
    static func url(_ base: String, query: [String:String]) -> URL {
        var value = URLComponents(string:base)!
        value.queryItems = query.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        value.percentEncodedQuery=value.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        return value.url!
    }
    static func status(_ code:Int) -> EngineFailure {
        var failure:EngineFailure
        if code == 429 { failure=EngineFailure(reason:"平台请求过于频繁，已停止本次请求。",solution:"请稍后再试；不要反复测试同一首歌曲。",code:"rate_limited") }
        else if [401,403].contains(code) { failure=EngineFailure(reason:"平台拒绝了当前请求。",solution:"请重新解析一次；仍失败时，请选择允许访问的其他歌曲版本或音源。",code:"source_unavailable") }
        else {failure=EngineFailure(reason:"当前来源暂未返回可用数据。",solution:"请稍后重试或换其他来源。",code:"source_unavailable")}
        failure.technical="HTTP \(code)";return failure
    }
}

private final class NativeAPIRedirectGuard:NSObject,URLSessionTaskDelegate {
    let origin:URL
    init(origin:URL){self.origin=origin}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        // API requests may carry an explicit session. Never forward it to a
        // different host, port, or plaintext redirect.
        guard request.url?.user==nil,request.url?.password==nil,
              request.url?.host==origin.host,request.url?.scheme==origin.scheme,request.url?.port==origin.port else{completionHandler(nil);return}
        completionHandler(request)
    }
}

/// One bounded stream. Preview stops at the cap even when the server ignores
/// Range, while downloads go straight to a private file rather than memory.
final class NativeAudioTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let sample:Data; let bytes:Int64; let response:HTTPURLResponse }
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Result,Error>?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var response:HTTPURLResponse?
    private var writer:FileHandle?
    private var sample=Data()
    private var bytes:Int64=0
    private var wholeRangeBytes:Int64?
    private var stopped=false
    private var started=false
    private var loopbackOrigin=false
    private let cap:Int64?
    private let destination:URL?
    private let maximumBytes:Int64
    private let progress:(Int64,Int64)->Void
    init(cap:Int64?=nil,destination:URL?=nil,maximumBytes:Int64=536_870_912,progress:@escaping(Int64,Int64)->Void={_,_ in}) {
        self.cap=cap;self.destination=destination;self.maximumBytes=maximumBytes;self.progress=progress
    }
    private func claimStart(url:URL) throws {
        lock.lock();defer{lock.unlock()}
        guard !started,maximumBytes>0,cap.map({$0>0 && $0<=maximumBytes}) ?? true else {
            throw EngineFailure(reason:"下载流已使用或读取范围无效，请重新发起任务。",code:"invalid_request")
        }
        started=true
        loopbackOrigin=["127.0.0.1","localhost","::1"].contains(url.host ?? "")
    }
    func run(url:URL,headers:[String:String]) async throws -> Result {
        guard url.user==nil,url.password==nil,url.scheme=="https" || (url.scheme=="http" && ["127.0.0.1","localhost","::1"].contains(url.host ?? "")) else{throw Self.unavailable()}
        // Claim before installing cancellation handling: a rejected duplicate
        // caller must neither replace nor cancel the original continuation.
        try claimStart(url:url)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock();self.continuation=continuation
                if stopped {lock.unlock();finish(.failure(CancellationError()));return}
                do {
                    if let destination=destination {
                        let descriptor=open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
                        guard descriptor>=0 else {throw EngineFailure(reason:"临时音频文件无法创建或目标已存在。",solution:"请检查保存目录权限和磁盘空间后重试。",code:"filesystem")}
                        writer=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
                    }
                    var request=URLRequest(url:url)
                    request.setValue(NativeHTTP.userAgent,forHTTPHeaderField:"User-Agent")
                    for (key,value) in headers where !["cookie","authorization","proxy-authorization"].contains(key.lowercased()) {request.setValue(value,forHTTPHeaderField:key)}
                    if let cap=cap {request.setValue("bytes=0-\(cap-1)",forHTTPHeaderField:"Range")}
                    let queue=OperationQueue();queue.maxConcurrentOperationCount=1
                    let session=URLSession(configuration:NativeHTTP.configuration(),delegate:self,delegateQueue:queue)
                    self.session=session;let task=session.dataTask(with:request);self.task=task
                    lock.unlock();task.resume()
                } catch {lock.unlock();finish(.failure(error))}
            }
        },onCancel:{self.cancel()})
    }
    func cancel() {
        lock.lock();stopped=true;let task=self.task;let pending=continuation != nil;lock.unlock()
        task?.cancel()
        if pending {finish(.failure(CancellationError()))}
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let value=response as? HTTPURLResponse,(200..<300).contains(value.statusCode) else {
            completionHandler(.cancel);finish(.failure(NativeHTTP.status((response as? HTTPURLResponse)?.statusCode ?? 0)));return
        }
        let mime=(value.mimeType ?? "").lowercased()
        guard !mime.hasPrefix("text/"),!mime.contains("json"),!mime.contains("mpegurl"),!mime.contains("xml") else {
            completionHandler(.cancel);finish(.failure(Self.unavailable()));return
        }
        var wholeRange:Int64?
        if cap==nil,value.statusCode==206 {
            guard let total=Self.completeRangeLength(value.value(forHTTPHeaderField:"Content-Range")) else {
                completionHandler(.cancel);finish(.failure(Self.incomplete()));return
            }
            if let length=value.value(forHTTPHeaderField:"Content-Length"),Int64(length) != total {
                completionHandler(.cancel);finish(.failure(Self.incomplete()));return
            }
            wholeRange=total
        }
        if cap==nil,(value.expectedContentLength>maximumBytes || (wholeRange.map{$0>maximumBytes} ?? false)) {
            completionHandler(.cancel);finish(.failure(Self.oversized()));return
        }
        lock.lock();self.response=value;wholeRangeBytes=wholeRange;lock.unlock();completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        completionHandler(Self.safeRedirect(request,loopbackOrigin:loopbackOrigin))
    }
    static func safeRedirect(_ request:URLRequest,loopbackOrigin:Bool) -> URLRequest? {
        guard let url=request.url,url.user==nil,url.password==nil else{return nil}
        let host=(url.host ?? "").lowercased(),local=["127.0.0.1","localhost","::1"].contains(host)
        guard loopbackOrigin || !local else{return nil}
        var clean=request
        if url.scheme=="http" && !local {
            let trusted=["music.126.net","music.163.com","kuwo.cn","kuwo.com"].contains{host==$0 || host.hasSuffix("."+$0)} || NativeAdditionalSources.trustedMediaHost(host)
            guard trusted,url.port==nil || url.port==80,var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return nil}
            // Legacy public redirects still spell CDN links as HTTP. Upgrade
            // only the same known host before making a request; never fall back.
            parts.scheme="https";parts.port=nil;guard let secure=parts.url else{return nil};clean.url=secure
        }
        guard clean.url?.scheme=="https" || (loopbackOrigin && local && clean.url?.scheme=="http") else{return nil}
        for name in ["Cookie","Authorization","Proxy-Authorization"] {clean.setValue(nil,forHTTPHeaderField:name)}
        return clean
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock()
        guard continuation != nil,!stopped else {lock.unlock();return}
        let count=cap.map{min(Int64(data.count),max(0,$0-bytes))} ?? Int64(data.count)
        // Check the budget before writing, sampling, or publishing progress.
        // A server may omit Content-Length or deliver one oversized chunk.
        guard bytes<=maximumBytes,count<=maximumBytes-bytes else {
            lock.unlock();finish(.failure(Self.oversized()));return
        }
        let chunk=Data(data.prefix(Int(count)))
        do {try writer?.write(contentsOf:chunk)} catch {lock.unlock();finish(.failure(EngineFailure(reason:"音频写入失败。",solution:"请检查磁盘空间或更换保存目录。",code:"filesystem")));return}
        if sample.count < 131072 {sample.append(chunk.prefix(131072-sample.count))}
        bytes += count
        let total=response?.expectedContentLength ?? -1,finished=cap.map{bytes >= $0} ?? false,value=bytes
        let result=response.map{Result(sample:sample,bytes:bytes,response:$0)}
        lock.unlock();progress(value,total)
        if finished,let result=result {finish(.success(result))}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        lock.lock();let result=response.map{Result(sample:sample,bytes:bytes,response:$0)},wholeRange=wholeRangeBytes,received=bytes;lock.unlock()
        if let wholeRange=wholeRange,received != wholeRange {finish(.failure(Self.incomplete()))}
        else if let error=error {finish(.failure(error))}
        else if let result=result {finish(.success(result))}
        else {finish(.failure(Self.unavailable()))}
    }
    private static func completeRangeLength(_ header:String?) -> Int64? {
        guard let header=header?.trimmingCharacters(in:.whitespacesAndNewlines),
              let regex=try? NSRegularExpression(pattern:"^bytes 0-([0-9]{1,19})/([0-9]{1,19})$",options:.caseInsensitive),
              let match=regex.firstMatch(in:header,range:NSRange(header.startIndex...,in:header)),
              let endRange=Range(match.range(at:1),in:header),let totalRange=Range(match.range(at:2),in:header),
              let end=Int64(header[endRange]),let total=Int64(header[totalRange]),total>0,end==total-1 else{return nil}
        return total
    }
    private static func incomplete() -> EngineFailure {EngineFailure(reason:"来源只返回了部分音频数据，未作为完整歌曲保存。",solution:"请重新解析一次；仍失败时，请换其他音源或歌曲版本。",code:"audio_incomplete")}
    private static func oversized() -> EngineFailure {EngineFailure(reason:"音频文件超过512 MB限制。",solution:"请核对歌曲版本或更换来源。",code:"source_response")}
    private func finish(_ result:Swift.Result<Result,Error>) {
        lock.lock();guard let continuation=continuation else {lock.unlock();return}
        self.continuation=nil;let writer=self.writer;self.writer=nil;let session=self.session;self.session=nil;lock.unlock()
        try? writer?.close();session?.invalidateAndCancel();continuation.resume(with:result)
    }
    static func unavailable() -> EngineFailure {EngineFailure(reason:"该版本的链接未返回有效音频。",solution:"请重试解析；仍失败时，请换其他音源或同名歌曲的其他版本。",code:"source_unavailable")}
    static func recognizable(_ data:Data) -> Bool {
        let b=[UInt8](data.prefix(16))
        return data.starts(with:Data("ID3".utf8)) || data.starts(with:Data("fLaC".utf8)) || data.starts(with:Data("OggS".utf8)) || (b.count >= 12 && String(bytes:b[0..<4],encoding:.ascii)=="RIFF" && String(bytes:b[8..<12],encoding:.ascii)=="WAVE") || (b.count >= 8 && String(bytes:b[4..<8],encoding:.ascii)=="ftyp") || (b.count >= 2 && b[0]==255 && b[1]&0xE0==0xE0)
    }
}
