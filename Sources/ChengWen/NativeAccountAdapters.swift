import Foundation

enum NativeAccountAdapters {
    typealias HTTP=(URL,[String:String],String,Data?) async throws->[String:Any]
    static let liveHTTP:HTTP={url,headers,method,body in try await NativeHTTP.json(url,headers:headers,method:method,body:body)}
    static let ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"
    static let kuwoSource="kwplayer_ar_12.2.2.0_newpcguanwangmobile.apk"
    static func text(_ value:Any?)->String {if let value=value as? String{return value};return (value as? NSNumber)?.stringValue ?? ""}
    static func positiveID(_ value:String)->Bool {!value.isEmpty && value.count<=32 && value.range(of:"^[0-9]+$",options:.regularExpression) != nil && value.contains{$0 != "0"}}
    static func denied(_ reason:String)->EngineFailure {EngineFailure(reason:reason,solution:"请确认该账号的会员、专辑购买及单曲下载权益；可更换同名版本或音源，不会自动退回匿名请求。",code:"account_permission")}
    static func form(_ fields:[String:String])->Data {
        Data(fields.keys.sorted().map{NativeKuwoCrypto.percent($0)+"="+NativeKuwoCrypto.percent(fields[$0] ?? "")}.joined(separator:"&").utf8)
    }
    static func request(_ url:URL,payload:[String:Any]?=nil,reference:[String:Any]?,store:NativeSessionStore,method:String="GET",fields:[String:String]?=nil) async throws->[String:Any] {
        try Task.checkCancellation()
        if let reference=reference{try store.assertCurrent(reference)}
        let host=url.host ?? ""
        guard url.scheme=="https",["music.163.com","www.kuwo.cn","loginserver.kuwo.cn","musicpay.kuwo.cn","anymatch.kuwo.cn"].contains(host),url.user==nil,url.password==nil,url.port==nil || url.port==443 else{throw EngineFailure(reason:"账号请求地址无效。",code:"account_response")}
        var headers=["User-Agent":ua]
        if let payload=payload {
            let agent=try NativeAccountValidation.userAgent(payload["user_agent"])
            let platform=host=="music.163.com" ? "netease" : "kuwo"
            let cookies=try filteredCookies(payload["cookies"],platform:platform)
            let scoped=cookies.filter {row in
                let domain=(row["domain"] as? String ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"."))
                let path=row["path"] as? String ?? "/"
                return (host==domain || host.hasSuffix("."+domain)) && url.path.hasPrefix(path)
            }
            headers["Cookie"]=scoped.map{($0["name"] as! String)+"="+($0["value"] as! String)}.joined(separator:"; ")
            headers["User-Agent"]=agent
            headers["Referer"]=platform=="netease" ? "https://music.163.com/" : "https://www.kuwo.cn/"
            if method=="POST"{headers["Origin"]=platform=="netease" ? "https://music.163.com" : "https://www.kuwo.cn"}
        }
        if fields != nil{headers["Content-Type"]="application/x-www-form-urlencoded"}
        let body:[String:Any]
        do{body=try await store.api(url,headers,method,fields.map(form))}
        catch is CancellationError{throw CancellationError()}
        catch let failure as EngineFailure {
            let code=failure.technical=="HTTP 401" ? "account_expired" : (["HTTP 403","HTTP 429"].contains(failure.technical) || failure.code=="rate_limited" ? "account_risk" : "")
            if !code.isEmpty {
                if let reference=reference{try? store.block(reference,code:code)}
                throw NativeSessionStore.auth(code=="account_expired" ? "登录状态已过期，请重新连接账号。" : "平台拒绝账号请求或要求额外验证，已停止自动重试。",code:code)
            }
            throw EngineFailure(reason:"账号接口暂未返回可用数据。",solution:"请稍后重试，不要反复提交。",code:"account_response")
        } catch{throw EngineFailure(reason:"账号接口连接失败。",solution:"请检查网络后重试。",code:"network")}
        try Task.checkCancellation()
        let nested=body["data"] as? [String:Any] ?? [:]
        let message=["msg","message","reason"].compactMap{body[$0] as? String}.joined(separator:" ").lowercased()
        if [text(body["code"]),text(nested["code"])].contains(where:{["-462","8821"].contains($0)}) || ["captcha","too frequent","风控","频繁","安全验证","验证码"].contains(where:{message.contains($0)}) {
            if let reference=reference{try? store.block(reference)}
            throw NativeSessionStore.auth("平台要求额外安全验证，已暂停该账号的自动请求。",code:"account_risk")
        }
        if let reference=reference{try store.assertCurrent(reference)}
        return body
    }
    static func filteredCookies(_ value:Any?,platform:String) throws->[[String:Any]] {
        guard let rows=value as? [[String:Any]],rows.count<=256 else{throw NativeSessionStore.auth()}
        let cookies=rows.compactMap {row->HTTPCookie? in
            guard let name=row["name"] as? String,let value=row["value"] as? String,let domain=row["domain"] as? String,!name.isEmpty,!value.isEmpty,name.count<=256,value.utf8.count<=16384,name.range(of:"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$",options:.regularExpression) != nil,!value.utf8.contains(where:{$0<32 || $0==127 || $0==59}),!domain.contains(where:{$0.isWhitespace}) else{return nil}
            var properties:[HTTPCookiePropertyKey:Any]=[.name:name,.value:value,.domain:domain,.path:row["path"] as? String ?? "/"]
            if let expires=row["expires"] as? NSNumber{properties[.expires]=Date(timeIntervalSince1970:expires.doubleValue)}
            if row["secure"] as? Bool==true{properties[.secure]="TRUE"}
            return HTTPCookie(properties:properties)
        }
        let result=NativeAccountValidation.cookieRecords(cookies,platform:platform)
        guard !result.isEmpty else{throw NativeSessionStore.auth()};return result
    }
    static func validate(_ platform:String,payload:[String:Any],reference:[String:Any]?,store:NativeSessionStore) async throws->[String:Any] {
        if platform=="netease" {
            let cookies=try filteredCookies(payload["cookies"],platform:platform)
            guard cookies.contains(where:{$0["name"] as? String=="MUSIC_U"}) else{throw NativeSessionStore.auth()}
            let body=try await request(NativeHTTP.url("https://music.163.com/api/w/nuser/account/get",query:["timestamp":String(Int(Date().timeIntervalSince1970*1000))]),payload:payload,reference:reference,store:store)
            let account=body["account"] as? [String:Any] ?? [:],profile=body["profile"] as? [String:Any] ?? [:]
            let uid=text(account["id"])
            guard text(body["code"])=="200",positiveID(uid),uid==text(profile["userId"]) else {
                if let reference=reference{try? store.block(reference,code:"account_expired")};throw NativeSessionStore.auth()
            }
            if let identity=payload["native_identity"] as? [String:Any],let claimed=identity["uid"] as? String,claimed != uid {throw NativeSessionStore.auth("网页账号与已验证会话不一致，请重新登录。",code:"account_changed")}
            return ["nickname":String((profile["nickname"] as? String ?? "网易云用户").prefix(60)),"verified":true]
        }
        guard platform=="kuwo" else{throw NativeMusicEngine.unsupported()}
        let (uid,sid,nickname)=try kuwoIdentity(payload)
        let web=try await request(URL(string:"https://www.kuwo.cn/api/user/checkLogin")!,payload:payload,reference:reference,store:store,method:"POST",fields:["uid":uid,"sid":sid])
        guard text(web["status"])=="200" else{if let reference=reference{try? store.block(reference,code:"account_expired")};throw NativeSessionStore.auth()}
        let device=try kuwoDevice(payload)
        let params=["type":"new_validate_ext","uid":uid,"sid":sid,"dev_id":device["id"]!,"dev_key":device["id"]!,"user":device["user"]!,"req_enc":"utf8","res_enc":"utf8","prod":"kwplayer_ar_12.2.2.0","corp":"kuwo","newver":"3","vipver":"12.2.2.0","source":kuwoSource,"p2p":"1","loginUid":uid,"loginSid":sid,"appuid":device["id"]!]
        let state=try await request(NativeHTTP.url("https://loginserver.kuwo.cn/u.s",query:params),reference:reference,store:store)
        guard state["result"] as? String=="ok",text(state["reason"]).isEmpty else{if let reference=reference{try? store.block(reference,code:"account_expired")};throw NativeSessionStore.auth("酷我会话未通过下载接口校验，请重新登录并连接。")}
        return ["nickname":nickname,"verified":true]
    }
    static func resolve(track:[String:Any],reference:[String:Any]) async throws->NativeResolvedAudio {
        guard let path=reference["store"] as? String else{throw NativeSessionStore.auth(code:"account_changed")}
        return try await resolve(track:track,reference:reference,store:NativeSessionStore(root:URL(fileURLWithPath:path)))
    }
    static func resolve(track:[String:Any],reference:[String:Any],store:NativeSessionStore) async throws->NativeResolvedAudio {
        let platform=track["source"] as? String ?? ""
        guard NativeSessionStore.platforms.contains(platform),reference["platform"] as? String==platform else{throw NativeSessionStore.auth(code:"account_changed")}
        return try await store.withOperation(platform) {
            let payload=try store.load(reference)
            _=try await validate(platform,payload:payload,reference:reference,store:store)
            let songID=try NativeMusicEngine.songID(track)
            let resolved:NativeResolvedAudio
            if platform=="netease" {
                let body=try await request(NativeHTTP.url("https://music.163.com/api/song/enhance/download/url",query:["id":songID,"br":"320000","timestamp":String(Int(Date().timeIntervalSince1970*1000))]),payload:payload,reference:reference,store:store)
                if ["301","302"].contains(text(body["code"])){try? store.block(reference,code:"account_expired");throw NativeSessionStore.auth()}
                let media=body["data"] as? [String:Any] ?? [:]
                guard text(body["code"])=="200",text(media["code"])=="200",text(media["id"])==songID,media["freeTrialInfo"]==nil || media["freeTrialInfo"] is NSNull,let raw=media["url"] as? String else{throw denied("网易云未授予当前账号这个版本的完整歌曲下载权限。")}
                let ext=(media["type"] as? String ?? "").lowercased()
                guard ["mp3","flac","m4a","aac","ogg","wav"].contains(ext) else{throw denied("平台返回加密或不支持的音频格式。")}
                let decoded=raw.removingPercentEncoding ?? raw
                for cookie in payload["cookies"] as? [[String:Any]] ?? [] where ["MUSIC_U","__csrf"].contains(cookie["name"] as? String ?? "") {
                    if let value=cookie["value"] as? String,!value.isEmpty,decoded.contains(value) {throw EngineFailure(reason:"平台音频地址包含账号会话信息，已停止下载。",code:"account_response")}
                }
                resolved=NativeResolvedAudio(url:try mediaURL(raw,hosts:["music.126.net","music.163.com"]),headers:["User-Agent":ua],expectedDuration:duration(track),container:ext)
            } else {resolved=try await resolveKuwo(track,payload:payload,reference:reference,store:store,songID:songID)}
            try store.assertCurrent(reference);try Task.checkCancellation();return resolved
        }
    }
    static func duration(_ track:[String:Any])->Double? {let value=NativeMusicEngine.number((track["metadata"] as? [String:Any])?["duration_s"]);return value.isFinite && value>0 ? value : nil}
    static func kuwoIdentity(_ payload:[String:Any]) throws->(String,String,String) {
        let rows=try filteredCookies(payload["cookies"],platform:"kuwo")
        let values=rows.reduce(into:[String:String]()){$0[$1["name"] as! String]=$1["value"] as? String}
        let uid=values["userid"] ?? values["uid"] ?? "",sid=String((values["sid"] ?? values["websid"] ?? "").split(separator:"_",maxSplits:1).first ?? "")
        guard positiveID(uid),!sid.isEmpty,sid.count<=4096,!["0","null","undefined"].contains(sid),!sid.contains(where:{$0.isWhitespace}) else{throw NativeSessionStore.auth("未找到有效的酷我登录会话，请在官方网页登录后重新连接。")}
        let nickname=values["uname3"] ?? values["username"] ?? "酷我用户"
        return (uid,sid,String((nickname.removingPercentEncoding ?? nickname).prefix(60)))
    }
    static func kuwoDevice(_ payload:[String:Any]) throws->[String:String] {
        guard let device=payload["device"] as? [String:String],let id=device["id"],id.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil,let user=device["user"],positiveID(user) else{throw NativeSessionStore.auth("酷我设备会话无效，请重新连接。")};return device
    }
    static func mediaURL(_ value:String,hosts:[String],secret:String="") throws->URL {
        guard var parts=URLComponents(string:value),let host=parts.host?.lowercased(),hosts.contains(where:{host==$0 || host.hasSuffix("."+$0)}),parts.user==nil,parts.password==nil,parts.port==nil || parts.port==443,secret.isEmpty || !(value.removingPercentEncoding ?? value).contains(secret) else{throw EngineFailure(reason:"平台未返回受信的HTTPS音频地址。",code:"account_response")}
        if parts.scheme=="http",parts.port==nil{parts.scheme="https"}
        guard parts.scheme=="https",let url=parts.url else{throw EngineFailure(reason:"平台未返回受信的HTTPS音频地址。",code:"account_response")};return url
    }
    static func resolveKuwo(_ track:[String:Any],payload:[String:Any],reference:[String:Any],store:NativeSessionStore,songID:String) async throws->NativeResolvedAudio {
        let (uid,sid,_)=try kuwoIdentity(payload),device=try kuwoDevice(payload)
        for (tag,bitrate,format) in [("S",320,"MP3H"),("H",128,"MP3128")] {
            let params=["newver":"2","clienttimestamp":String(Int(Date().timeIntervalSince1970*1000)),"uid":uid,"sid":sid,"from":"ar","deviceid":device["user"]!,"ver":"12.2.2.0","src":kuwoSource,"appuid":device["id"]!,"allpay":"0","notrace":"1","oaid":"","vipMode":"0","op":"query","action":"download","signver":"new","filter":"no","apiversion":"4","local":"0","quality":tag,"preload":"0","ids":songID]
            let rights=try await request(NativeHTTP.url("https://musicpay.kuwo.cn/music.pay",query:params),reference:reference,store:store)
            guard let grant=try kuwoGrant(rights,uid:uid,rid:songID,tag:tag,bitrate:bitrate,format:format) else{continue}
            let values=["user":device["user"]!,"prod":"kwplayer_ar_12.2.2.0","corp":"kuwo","newver":"3","vipver":"12.2.2.0","source":kuwoSource,"p2p":"1","q36":"f2ce3c2ef68ddfd1b2bea7ed00001f314716","approval":"false","loginUid":uid,"loginSid":sid,"appuid":device["id"]!,"allpay":"0","notrace":"1","oaid":"","vipMode":"0","type":"convert_url_with_sign","format":"mp3","sig":"0","rid":songID,"priority":"bitrate","network":"WIFI","localUid":"-1","mode":"download","token":grant["token"]!,"bc_token":"","uid":device["id"]!,"downloadPay":grant["ndown"]!,"playPay":grant["nplay"]!,"payUid":uid,"isstar":"false","surl":"1","apiv":"1","aiOp":"","dev_type":"ChengWen","br":"\(bitrate)kmp3","timestamp":grant["timestamp"]!]
            let media=try await request(NativeHTTP.url("https://anymatch.kuwo.cn/mobi.s",query:["f":"kwxs","q":try NativeKuwoCrypto.seal(values)]),reference:reference,store:store)
            return try kuwoMedia(media,rid:songID,bitrate:bitrate,sid:sid,expectedDuration:duration(track))
        }
        throw denied("酷我未授予当前账号完整歌曲的MP3下载权限。")
    }
    static func kuwoGrant(_ body:[String:Any],uid:String,rid:String,tag:String,bitrate:Int,format:String) throws->[String:String]? {
        guard body["result"] as? String=="ok",["","0"].contains(text(body["errorcode"])),text(body["uid"])==uid else{throw denied("酷我拒绝了当前账号的歌曲下载授权。")}
        guard let songs=body["songs"] as? [[String:Any]],songs.count==1,text(songs[0]["id"])==rid,positiveID(text(body["timestamp"])) else{throw EngineFailure(reason:"酷我下载授权信息不完整或歌曲不匹配。",code:"account_response")}
        let song=songs[0],pay=song["payInfo"] as? [String:Any] ?? [:]
        if !["","0"].contains(text(pay["cannotDownload"])) {return nil}
        for row in song["audio"] as? [[String:Any]] ?? [] {
            guard row["quality"] as? String==tag,text(row["br"])==String(bitrate),text(row["fmt"]).uppercased()==format else{continue}
            let policy=row["policy"] as? String,cost=row["cost"] as? NSNumber
            let permitted=(policy=="" && row["price"] as? NSNumber==0) || (policy=="vip" && cost != nil && cost!.doubleValue.isFinite && cost!.doubleValue<=0) || ["song","album"].contains(policy ?? "")
            guard text(row["st"])=="0",text(row["avaliable"]) != "0",permitted,let token=(song["token"] as? [String:Any])?[tag] as? String,!token.isEmpty,token.count<=8192 else{continue}
            let play=text(pay["nplay"]),download=text(pay["ndown"])
            guard [play,download].allSatisfy({!$0.isEmpty && $0.count<=32 && $0.allSatisfy{$0=="0" || $0=="1"}}) else{throw denied("酷我没有返回完整的下载授权凭据。")}
            return ["token":token,"timestamp":text(body["timestamp"]),"nplay":play,"ndown":download]
        }
        return nil
    }
    static func kuwoMedia(_ body:[String:Any],rid:String,bitrate:Int,sid:String,expectedDuration:Double?) throws->NativeResolvedAudio {
        if ["4015","4017"].contains(text(body["code"])){throw NativeSessionStore.auth()}
        guard text(body["code"])=="200" else{throw denied("酷我没有返回获准下载的完整音频。")}
        let data=body["data"] as? [String:Any] ?? [:]
        let seconds=NativeMusicEngine.number(body["duration"] ?? data["duration"])
        let full=(text(data["startPos"])=="0" && text(data["endPos"])=="0") || (data["startPos"]==nil && data["endPos"]==nil && data["media_basic_info"] != nil && !(data["media_basic_info"] is NSNull) && NativeMusicEngine.number(data["fileSize"])>0 && !text(data["filePath"]).isEmpty)
        guard text(data["rid"])==rid,text(data["type"])=="0",full,seconds.isFinite,seconds>0 else{throw denied("酷我返回试听片段或不完整音频，未保存为整首歌曲。")}
        guard data["format"] as? String=="mp3",text(data["ekey"]).isEmpty,[String(bitrate),String(bitrate*1000)].contains(text(data["bitrate"])) else{throw denied("酷我返回加密或不匹配的音频格式，当前不进行解密。")}
        if !["",sid].contains(text(body["loginSid"])) {throw NativeSessionStore.auth("酷我账号会话已变化，请重新连接。",code:"account_changed")}
        let url=try mediaURL(text(data["surl"] ?? data["url"]),hosts:["kuwo.cn","kuwo.com"],secret:sid)
        return NativeResolvedAudio(url:url,headers:["User-Agent":ua],expectedDuration:expectedDuration ?? seconds,container:"mp3")
    }
}
