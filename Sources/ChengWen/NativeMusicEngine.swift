import Foundation
import CryptoKit
import Darwin

struct NativeResolvedAudio {
    var url:URL
    var headers:[String:String]=[:]
    var expectedDuration:Double?=nil
    var lyric:String?=nil
    var container:String?=nil
}

/// Narrow I/O boundary used by synthetic failure/cancellation tests. Production
/// uses the system calls below; it never installs process-wide mutable hooks.
struct NativePublishIO {
    var read:(Int32,UnsafeMutableRawPointer?,Int)->Int = {Darwin.read($0,$1,$2)}
    var write:(Int32,UnsafeRawPointer?,Int)->Int = {Darwin.write($0,$1,$2)}
    var synchronize:(Int32)->Int32 = {Darwin.fsync($0)}
    var afterCreate:() throws -> Void = {}
}

enum NativeMusicEngine {
    typealias Event = (String,[String:Any])->Void
    static func execute(_ operation:String,payload:[String:Any],onEvent:@escaping Event) async throws -> [String:Any] {
        try Task.checkCancellation()
        switch operation {
        case "search": return try await search(payload,event:onEvent)
        case "probe","download":
            guard let track=payload["track"] as? [String:Any],let source=track["source"] as? String,MusicSource.available.contains(where:{$0.id==source}) else {throw unsupported()}
            let resolved=try await resolve(track)
            if operation=="probe" {return try await probe(resolved)}
            guard let directory=payload["directory"] as? String,!directory.isEmpty else {throw EngineFailure(reason:"请先选择保存目录。",code:"filesystem")}
            return try await download(track,resolved:resolved,directory:URL(fileURLWithPath:(directory as NSString).expandingTildeInPath),format:payload["format"] as? String ?? "mp3",saveLyrics:payload["save_lyrics"] as? Bool ?? true,event:onEvent)
        case "health": return try await health()
        case "selftest": return try await NativeEngineSmoke.run()
        case "accounts","account","activate_account": return try await NativeSessionStore.perform(operation:operation,payload:payload)
        default: throw EngineFailure(reason:"不支持的音乐操作。",code:"invalid_request")
        }
    }
    static func unsupported() -> EngineFailure {EngineFailure(reason:"这个来源尚未接入当前原生版本。",solution:"请选择当前支持的音乐来源重新搜索。",code:"source_unsupported")}
    static func duration(_ seconds:Double) -> String {seconds.isFinite && seconds>0 && seconds<360_000 ? "\(Int(seconds)/60):\(String(format:"%02d",Int(seconds)%60))" : "—"}
    static func number(_ value:Any?) -> Double {if let value=value as? NSNumber{return value.doubleValue};return Double(value as? String ?? "") ?? 0}
    static func clean(_ value:Any?,fallback:String="—") -> String {
        var text=(value as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        text=text.replacingOccurrences(of:"\\\\+u0026",with:"&",options:.regularExpression)
        for (from,to) in [("&amp;","&"),("&nbsp;"," "),("&quot;","\""),("&#39;","'"),("&lt;","<"),("&gt;",">")] {text=text.replacingOccurrences(of:from,with:to)}
        return text.isEmpty || text=="NULL" ? fallback : String(text.prefix(500))
    }
    static func search(_ payload:[String:Any],event:@escaping Event) async throws -> [String:Any] {
        let keyword=(payload["keyword"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let source=payload["source"] as? String ?? ""
        guard !keyword.isEmpty,keyword.count<=100 else {throw EngineFailure(reason:"请输入歌名或艺术家。",code:"invalid_request")}
        guard MusicSource.available.contains(where:{$0.id==source}) else {throw unsupported()}
        let limit=max(1,min(30,payload["limit"] as? Int ?? 10))
        if NativeAdditionalSources.ids.contains(source) {
            let tracks=try await readSearchValue {try await NativeAdditionalSources.search(source:source,keyword:keyword,limit:limit)}
            for track in tracks {try Task.checkCancellation();event("track",track)}
            return ["source":source,"count":tracks.count]
        }
        let url=source=="netease" ? NativeHTTP.url("https://music.163.com/api/search/get/web",query:["s":keyword,"type":"1","limit":String(limit),"offset":"0"]) : NativeHTTP.url("https://search.kuwo.cn/r.s",query:["all":keyword,"ft":"music","client":"kt","pn":"0","rn":String(limit),"rformat":"json","encoding":"utf8"])
        let headers=["Referer":source=="netease" ? "https://music.163.com/" : "https://www.kuwo.cn/"]
        let json=try await readSearch {try await NativeHTTP.json(url,headers:headers)}
        if source=="netease",number(json["code"]) != 200 {throw NativeAudioTransfer.unavailable()}
        let songs=source=="netease" ? ((json["result"] as? [String:Any])?["songs"] as? [[String:Any]] ?? []) : (json["abslist"] as? [[String:Any]] ?? [])
        var count=0
        for song in songs.prefix(limit) {
            try Task.checkCancellation()
            let track=searchTrack(song,source:source)
            guard !track.isEmpty else {continue}
            event("track",track);count+=1
        }
        return ["source":source,"count":count]
    }
    /// Only anonymous search uses this bounded retry. Account requests and
    /// platform denials are never repeated automatically.
    static func readSearch(_ read:() async throws->[String:Any]) async throws->[String:Any] {
        try await readSearchValue(read)
    }
    static func readSearchValue<T>(_ read:() async throws->T) async throws->T {
        do {return try await read()}
        catch {
            try Task.checkCancellation()
            let failure=error as NSError
            guard failure.domain==NSURLErrorDomain,[NSURLErrorTimedOut,NSURLErrorNetworkConnectionLost].contains(failure.code) else{throw error}
            try await Task.sleep(nanoseconds:750_000_000)
            return try await read()
        }
    }
    static func searchTrack(_ song:[String:Any],source:String) -> [String:Any] {
        let rawID=source=="netease" ? ((song["id"] as? NSNumber)?.stringValue ?? song["id"] as? String ?? "") : (song["MUSICRID"] as? String ?? "").replacingOccurrences(of:"MUSIC_",with:"")
        guard validID(rawID) else{return [:]}
        let artists=(song["artists"] as? [[String:Any]] ?? []).map{clean($0["name"],fallback:"")}.filter{!$0.isEmpty}.joined(separator:" / ")
        let seconds=source=="netease" ? number(song["duration"])/1000 : number(song["DURATION"])
        let album=song["album"] as? [String:Any] ?? [:]
        let id=SHA256.hash(data:Data("\(source):\(rawID)".utf8)).map{String(format:"%02x",$0)}.joined().prefix(24)
        return ["id":String(id),"title":clean(song[source=="netease" ? "name" : "NAME"],fallback:"未命名音频"),"artist":source=="netease" ? clean(artists,fallback:"未知艺术家") : clean(song["ARTIST"],fallback:"未知艺术家"),"album":clean(source=="netease" ? album["name"] : song["ALBUM"]),"source":source,"duration":duration(seconds),"ext":"mp3","url":source=="netease" ? "https://music.163.com/song?id=\(rawID)" : "https://www.kuwo.cn/yinyue/\(rawID)","metadata":["duration_s":seconds,"song_id":rawID]]
    }
    static func songID(_ track:[String:Any]) throws -> String {
        if let value=(track["metadata"] as? [String:Any])?["song_id"] as? String,validID(value) {return value}
        let text=track["url"] as? String ?? "",source=track["source"] as? String ?? ""
        let pattern=source=="netease" ? "[?&]id=([0-9]+)" : "/yinyue/([0-9]+)"
        if let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range(at:1),in:text) {return String(text[range])}
        throw EngineFailure(reason:"歌曲链接已失效，请重新搜索。",code:"source_response")
    }
    static func validID(_ value:String) -> Bool {value.range(of:"^[1-9][0-9]{0,18}$",options:.regularExpression) != nil && Int64(value) != nil}
    static func resolve(_ track:[String:Any]) async throws -> NativeResolvedAudio {
        let source=track["source"] as? String ?? ""
        if NativeAdditionalSources.ids.contains(source) {return try await NativeAdditionalSources.resolve(track)}
        if let ref=(track["metadata"] as? [String:Any])?["account_ref"] as? [String:Any] {return try await NativeAccountAdapters.resolve(track:track,reference:ref)}
        let id=try songID(track)
        let seconds=number((track["metadata"] as? [String:Any])?["duration_s"])
        if source=="netease" {return NativeResolvedAudio(url:NativeHTTP.url("https://music.163.com/song/media/outer/url",query:["id":id+".mp3"]),headers:["Referer":"https://music.163.com/"],expectedDuration:seconds>0 ? seconds : nil,container:"mp3")}
        guard source=="kuwo" else{throw unsupported()}
        let url=NativeHTTP.url("https://antiserver.kuwo.cn/anti.s",query:["format":"mp3","rid":"MUSIC_"+id,"type":"convert_url","response":"url"])
        let (data,_)=try await NativeHTTP.data(url,headers:["Referer":"https://www.kuwo.cn/"])
        let value=(String(data:data,encoding:.utf8) ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard var parts=URLComponents(string:value),let host=parts.host,["kuwo.cn","kuwo.com"].contains(where:{host==$0 || host.hasSuffix("."+$0)}),parts.user==nil,parts.password==nil else {throw NativeAudioTransfer.unavailable()}
        if parts.scheme=="http" {parts.scheme="https"}
        guard parts.scheme=="https",parts.port==nil || parts.port==443,let media=parts.url else {throw NativeAudioTransfer.unavailable()}
        return NativeResolvedAudio(url:media,expectedDuration:seconds>0 ? seconds : nil,container:"mp3")
    }
    static func probe(_ resolved:NativeResolvedAudio) async throws -> [String:Any] {
        let transfer=NativeAudioTransfer(cap:131072)
        let result=try await transfer.run(url:resolved.url,headers:resolved.headers)
        guard result.bytes>0,NativeAudioTransfer.recognizable(result.sample) else{throw NativeAudioTransfer.unavailable()}
        return ["sample_bytes":result.bytes,"detail":"已试读音频数据；完整性以实际下载校验为准。"]
    }
    static func inspect(_ file:URL,expected:Double?=nil) async throws -> (String,Double,String) {
        guard let ffprobe=NativeTool.ffprobe() else{throw EngineFailure(reason:"缺少配套的FFprobe，无法验证完整音频。",solution:"请在运行环境测试中安装同一套FFmpeg和FFprobe。",code:"dependency")}
        let data=try await NativeTool.run(ffprobe,["-v","error","-protocol_whitelist","file,pipe","-show_streams","-show_format","-of","json",file.path])
        guard let info=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let streams=info["streams"] as? [[String:Any]],let audio=streams.first(where:{$0["codec_type"] as? String=="audio"}) else{throw EngineFailure(reason:"下载内容不是有效的音频文件。",solution:"请换其他歌曲版本或音源。",code:"audio_invalid")}
        let format=info["format"] as? [String:Any] ?? [:]
        let seconds=max(number(format["duration"]),number(audio["duration"]))
        guard seconds.isFinite,seconds>0 else{throw EngineFailure(reason:"音频时长无效，未保存文件。",code:"audio_invalid")}
        if let expected=expected,expected>=60,seconds<min(expected*0.85,expected-15) {throw EngineFailure(reason:"下载音频明显短于歌曲时长，可能仅为试听片段。",solution:"请确认该版本的下载权益，或换其他音源。",code:"audio_incomplete")}
        return (audio["codec_name"] as? String ?? "",seconds,format["format_name"] as? String ?? "")
    }
    static func download(_ track:[String:Any],resolved:NativeResolvedAudio,directory:URL,format:String,saveLyrics:Bool,event:@escaping Event,lyricRequest:(String) async throws -> String?=NativeMusicEngine.fetchLyric) async throws -> [String:Any] {
        guard AudioFormat.all.contains(where:{$0.id==format}) else{throw EngineFailure(reason:"不支持的保存格式。",code:"invalid_request")}
        guard NativeTool.find("ffmpeg") != nil,NativeTool.ffprobe() != nil else{throw EngineFailure(reason:"缺少FFmpeg或配套FFprobe，暂时无法验证完整音频。",solution:"请先打开运行环境测试安装兼容工具。",code:"dependency")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let stage=directory.appendingPathComponent(".chengwen-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:stage)}
        let input=stage.appendingPathComponent("source.audio")
        event("progress",["stage":"downloading","percent":0,"detail":"正在下载音频…"])
        let transfer=NativeAudioTransfer(destination:input){bytes,total in
            event("progress",["stage":"downloading","percent":total>0 ? min(90,Int(Double(bytes)/Double(total)*90)) : -1,"detail":total>0 ? "正在下载音频…" : "正在接收音频数据…"])
        }
        let response=try await transfer.run(url:resolved.url,headers:resolved.headers)
        try Task.checkCancellation()
        guard NativeAudioTransfer.recognizable(response.sample) else {throw NativeAudioTransfer.unavailable()}
        let original=try await inspect(input,expected:resolved.expectedDuration)
        let extensions=["mp3":"mp3","aac":"m4a","alac":"m4a","flac":"flac","pcm_s16le":"wav","pcm_s24le":"wav","vorbis":"ogg","opus":"ogg"]
        let originalExt=original.2.contains("wav") ? "wav" : original.0=="aac" ? (original.2.contains("mov") ? "m4a" : "aac") : extensions[original.0] ?? resolved.container ?? "m4a"
        let ext=format=="original" ? originalExt : format
        guard ["mp3","m4a","flac","wav","ogg","aac"].contains(ext) else{throw EngineFailure(reason:"来源音频格式不支持。",code:"audio_invalid")}
        let output=stage.appendingPathComponent("output."+ext)
        if format=="original" {try FileManager.default.copyItem(at:input,to:output)}
        else {
            guard let ffmpeg=NativeTool.find("ffmpeg") else{throw EngineFailure(reason:"缺少FFmpeg，无法转换格式。",solution:"请打开运行环境测试安装兼容工具。",code:"dependency")}
            event("progress",["stage":"converting","percent":-1,"detail":"正在转换为 \(format.uppercased())…"])
            let codecs:[String:[String]]=["mp3":["-c:a","libmp3lame","-b:a","320k"],"m4a":["-c:a","aac","-b:a","256k"],"flac":["-c:a","flac"],"wav":["-c:a","pcm_s16le"]]
            let args=["-nostdin","-hide_banner","-loglevel","error","-xerror","-protocol_whitelist","file,pipe","-i",input.path,"-map","0:a:0","-vn"]+(codecs[format] ?? [])+["-metadata","title="+clean(track["title"],fallback:""),"-metadata","artist="+clean(track["artist"],fallback:""),output.path]
            _=try await NativeTool.run(ffmpeg,args,timeout:1800)
        }
        let final=try await inspect(output,expected:original.1)
        guard abs(final.1-original.1)<=max(2,original.1*0.02) else{throw EngineFailure(reason:"转换后的音频时长不正确，未保存文件。",code:"audio_invalid")}
        let expectedCodecs:[String:Set<String>]=["mp3":["mp3"],"m4a":["aac"],"flac":["flac"],"wav":["pcm_s16le"]]
        if let codecs=expectedCodecs[format],!codecs.contains(final.0) {throw EngineFailure(reason:"转换结果与选择的音频编码不一致。",code:"audio_invalid")}
        if format=="m4a",!final.2.contains("mov") {throw EngineFailure(reason:"转换结果不是M4A容器。",code:"audio_invalid")}
        let decoded=try await decodedDuration(output)
        guard abs(decoded-final.1)<=max(1,final.1*0.02) else {throw EngineFailure(reason:"音频头标注时长与实际可解码内容不符，未保存不完整文件。",solution:"请换其他歌曲版本或音源。",code:"audio_incomplete")}
        try Task.checkCancellation()
        if let reference=(track["metadata"] as? [String:Any])?["account_ref"] as? [String:Any] {try NativeSessionStore.validateReference(reference)}
        let name=safeName(clean(track["title"],fallback:"未命名音频")+" - "+clean(track["artist"],fallback:"未知艺术家"))
        let published=try publish(output,in:directory,name:name,ext:ext)
        var warnings=[String]()
        if saveLyrics {
            var lyric=resolved.lyric
            if lyric==nil,track["source"] as? String=="netease",let id=try? songID(track) {
                // Audio has already committed successfully. A failed or
                // cancelled lyric request must not hide that saved file.
                do {lyric=try await lyricRequest(id)}
                catch {warnings.append("音频已保存，歌词未能获取。")}
            }
            if let lyric=lyric,!lyric.isEmpty {
                let path=published.deletingPathExtension().appendingPathExtension("lrc")
                do {try Data(lyric.utf8).write(to:path,options:.withoutOverwriting)} catch {warnings.append("音频已保存，歌词未能保存。")}
            }
        }
        event("progress",["stage":"completed","percent":100,"detail":"已保存到本地"])
        let authenticated = !NativeAdditionalSources.ids.contains(track["source"] as? String ?? "") && (track["metadata"] as? [String:Any])?["account_ref"] != nil
        return ["path":published.path,"duration":decoded,"codec":final.0,"warnings":warnings,"full_verified":true,"anonymous":!authenticated]
    }
    static func fetchLyric(_ id:String) async throws -> String? {
        let data=try await NativeHTTP.json(NativeHTTP.url("https://music.163.com/api/song/lyric",query:["id":id,"lv":"-1"]))
        return (data["lrc"] as? [String:Any])?["lyric"] as? String
    }
    static func decodedDuration(_ file:URL) async throws -> Double {
        guard let ffmpeg=NativeTool.find("ffmpeg") else {throw EngineFailure(reason:"缺少FFmpeg，无法验证整首音频。",solution:"请打开运行环境测试安装FFmpeg和配套FFprobe。",code:"dependency")}
        let data=try await NativeTool.run(ffmpeg,["-nostdin","-hide_banner","-loglevel","error","-xerror","-protocol_whitelist","file,pipe","-i",file.path,"-map","0:a:0","-vn","-progress","pipe:1","-nostats","-f","null","-"],timeout:1800)
        let text=String(data:data,encoding:.utf8) ?? ""
        let times=text.split(separator:"\n").compactMap {line -> Double? in
            guard line.hasPrefix("out_time_us="),let value=Double(line.dropFirst(12)),value.isFinite else{return nil};return value/1_000_000
        }
        guard let seconds=times.last,seconds>0 else{throw EngineFailure(reason:"音频无法完整解码。",code:"audio_invalid")}
        return seconds
    }
    static func safeName(_ value:String) -> String {
        let forbidden=CharacterSet(charactersIn:"/\\:\0\n\r\t*?\"<>|").union(.controlCharacters)
        let name=value.components(separatedBy:forbidden).joined(separator:"_").trimmingCharacters(in:CharacterSet(charactersIn:" ."))
        var bounded=""
        for character in name {
            if bounded.utf8.count+String(character).utf8.count>180 {break}
            bounded.append(character)
        }
        return bounded.isEmpty ? "音频" : bounded
    }
    static func publish(_ source:URL,in directory:URL,name:String,ext:String) throws -> URL {
        try Task.checkCancellation()
        guard ["mp3","m4a","flac","wav","ogg","aac"].contains(ext) else {
            throw EngineFailure(reason:"不支持的音频文件扩展名。",solution:"请选择支持的音频保存格式后重试。",code:"invalid_request")
        }
        let input=try openPublicationSource(source)
        defer{close(input)}
        for index in 0..<1000 {
            try Task.checkCancellation()
            guard ownsPublication(source,descriptor:input) else {
                throw EngineFailure(reason:"临时音频在保存前被替换。",solution:"请重新下载该歌曲。",code:"filesystem")
            }
            let path=directory.appendingPathComponent(name+(index==0 ? "" : " (\(index+1))")+"."+ext)
            // The staging directory is inside the destination volume. Exclusive
            // rename is one same-filesystem commit without requiring a hard
            // link. ExFAT does not implement exclusive rename: only that
            // unsupported-operation result enables the documented non-atomic
            // copy compatibility path. No plain overwriting rename is used.
            if renamex_np(source.path,path.path,UInt32(RENAME_EXCL))==0 {return path}
            let failure=errno
            if [ENOTSUP,EOPNOTSUPP].contains(failure) {
                if try copyForPublication(source,to:path) {return path}
            } else if failure != EEXIST {throw publishFailure(failure)}
        }
        throw EngineFailure(reason:"目录中同名文件过多，请更换保存目录。",solution:"请选择其他保存目录，或整理同名文件后重试。",code:"filesystem")
    }
    /// Compatibility only for volumes without RENAME_EXCL (notably ExFAT).
    /// O_EXCL/O_NOFOLLOW preserves other directory entries, but this destination
    /// is visible while copying. A process crash/power loss can leave a partial
    /// file; successful fsync is the commit point, not atomic visibility.
    static func copyForPublication(_ source:URL,to target:URL,io:NativePublishIO=NativePublishIO()) throws -> Bool {
        try Task.checkCancellation()
        let input=try openPublicationSource(source)
        defer{close(input)}
        var initial=stat()
        guard fstat(input,&initial)==0 else{throw publishFailure(errno)}
        try Task.checkCancellation()
        let output=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600))
        if output<0 {
            let failure=errno
            if failure==EEXIST{return false}
            throw publishFailure(failure)
        }
        var committed=false
        defer {
            if !committed {removeOwnedPublication(target,descriptor:output)}
            close(output)
        }
        try io.afterCreate()
        var buffer=[UInt8](repeating:0,count:65536),copied:Int64=0
        while true {
            try Task.checkCancellation()
            let count=buffer.withUnsafeMutableBytes{io.read(input,$0.baseAddress,$0.count)}
            if count<0 {
                let failure=errno
                if failure==EINTR{continue}
                throw publishFailure(failure)
            }
            if count==0{break}
            guard copied<=initial.st_size,Int64(count)<=initial.st_size-copied else {
                throw EngineFailure(reason:"临时音频在保存期间发生变化。",solution:"请重新下载该歌曲。",code:"filesystem")
            }
            try buffer.withUnsafeBytes {bytes in
                var written=0
                while written<count {
                    try Task.checkCancellation()
                    let amount=io.write(output,bytes.baseAddress?.advanced(by:written),count-written)
                    if amount<0 {
                        let failure=errno
                        if failure==EINTR{continue}
                        throw publishFailure(failure)
                    }
                    guard amount>0 else{throw publishFailure(EIO)}
                    written+=amount
                }
            }
            copied+=Int64(count)
        }
        var final=stat()
        guard fstat(input,&final)==0 else{throw publishFailure(errno)}
        guard copied==initial.st_size,final.st_size==initial.st_size,
              final.st_mtimespec.tv_sec==initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec==initial.st_mtimespec.tv_nsec else {
            throw EngineFailure(reason:"临时音频在保存期间发生变化。",solution:"请重新下载该歌曲。",code:"filesystem")
        }
        guard ownsPublication(target,descriptor:output) else{throw replacedPublication()}
        while true {
            try Task.checkCancellation()
            if io.synchronize(output)==0{break}
            let failure=errno
            if failure != EINTR{throw publishFailure(failure)}
        }
        guard ownsPublication(target,descriptor:output) else{throw replacedPublication()}
        // Do not throw cancellation after this point: fully flushed audio is a
        // successful save, including when a later lyric request is cancelled.
        committed=true
        removeOwnedPublication(source,descriptor:input)
        return true
    }
    private static func openPublicationSource(_ source:URL) throws -> Int32 {
        // A replaced or unexpected FIFO must not block open() before type
        // validation or cancellation can run. NONBLOCK has no effect on normal
        // regular audio files; NOFOLLOW also rejects a substituted symlink.
        let descriptor=open(source.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else{throw publishFailure(errno)}
        var info=stat()
        guard fstat(descriptor,&info)==0 else {
            let failure=errno;close(descriptor);throw publishFailure(failure)
        }
        guard info.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),info.st_size>=0 else {
            close(descriptor)
            throw EngineFailure(reason:"临时音频不是可保存的普通文件。",solution:"请重新下载该歌曲。",code:"filesystem")
        }
        return descriptor
    }
    private static func replacedPublication()->EngineFailure {
        EngineFailure(reason:"保存目标在写入期间被其他程序替换，未将其计为下载完成。",solution:"请关闭会修改同名文件的其他程序，或选择其他保存目录后重试。",code:"filesystem")
    }
    private static func ownsPublication(_ path:URL,descriptor:Int32)->Bool {
        var opened=stat(),entry=stat()
        return fstat(descriptor,&opened)==0 && lstat(path.path,&entry)==0 &&
            opened.st_dev==entry.st_dev && opened.st_ino==entry.st_ino &&
            entry.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG)
    }
    private static func removeOwnedPublication(_ path:URL,descriptor:Int32) {
        guard ownsPublication(path,descriptor:descriptor) else{return}
        // Retain the descriptor until after the identity check / unlink. This
        // avoids deleting a path already replaced by another writer, although
        // POSIX cannot condition unlink on inode against a hostile same-UID
        // process racing between this check and the unlink itself.
        _=unlink(path.path)
    }
    static func publishFailure(_ status:Int32) -> EngineFailure {
        let reason:String,solution:String
        switch status {
        case EACCES,EPERM,EROFS:
            reason="保存位置没有写入权限，或磁盘为只读。"
            solution="请检查磁盘与目录权限，或选择其他可写的保存目录。"
        case ENOSPC,EDQUOT:
            reason="保存位置的磁盘空间或配额不足。"
            solution="请释放磁盘空间，或选择空间充足的保存目录后重试。"
        case ENOTSUP,EOPNOTSUPP,ENOSYS,EINVAL:
            reason="这个文件系统暂不支持安全的原子保存。"
            solution="请选择支持原子重命名的本地磁盘目录后重试；不会采用可能覆盖已有文件的保存方式。"
        case EXDEV:
            reason="临时音频与保存位置不在同一个文件系统，无法原子保存。"
            solution="请重新选择稳定的保存目录后重试，不要在下载期间替换挂载点。"
        case ENOENT,ENOTDIR:
            reason="保存目录或临时文件已不存在，无法完成保存。"
            solution="请确认磁盘仍已连接，并重新选择保存目录后重试。"
        case EIO,ENXIO:
            reason="保存磁盘发生读写错误，音频未能保存。"
            solution="请检查外置磁盘连接与磁盘状态，或换其他保存目录重试。"
        default:
            reason="音频保存失败。"
            solution="请检查磁盘状态、空间和目录权限后重试。"
        }
        var failure=EngineFailure(reason:reason,solution:solution,code:"filesystem")
        failure.technical="POSIX errno \(status)"
        return failure
    }
    static func health() async throws -> [String:Any] {
        var items:[[String:Any]]=[["key":"engine","title":"音乐下载引擎","state":"ready","version":AppVersion.current,"path":"","detail":"六个音源适配器已内置，无需另行安装。歌曲可用性以逐曲试读与下载校验为准。","required":true]]
        for (key,path) in [("ffmpeg",NativeTool.find("ffmpeg")),("ffprobe",NativeTool.ffprobe())] {
            try Task.checkCancellation()
            var item:[String:Any]=["key":key,"title":key=="ffmpeg" ? "FFmpeg" : "FFprobe","path":path ?? "","state":"missing","version":"","detail":"未找到兼容的音频工具。","required":true]
            if let path=path {
                do {let data=try await NativeTool.run(path,["-version"],timeout:8);let line=String(data:data,encoding:.utf8)?.split(separator:"\n").first.map(String.init) ?? "可用";item["state"]="ready";item["version"]=line.split(separator:" ").dropFirst(2).first.map(String.init) ?? line;item["detail"]=key=="ffmpeg" ? "可实际运行，用于格式转换与完整解码校验。" : "可实际运行，与 FFmpeg 位于同一目录，用于读取音频信息。"} catch {item["state"]="failed";item["detail"]="工具无法启动，请安装支持当前系统与芯片的版本。"}
            }
            items.append(item)
        }
        return ["items":items]
    }
}
