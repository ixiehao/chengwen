import Foundation
import Security

protocol NativeSessionVault:Sendable {
    func load(account:String) throws -> Data?
    func save(account:String,data:Data) throws
    func delete(account:String) throws
}

struct NativeSystemSessionVault:NativeSessionVault {
    private func query(_ account:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:NativeSystemAccountVault.service,kSecAttrAccount as String:account]
    }
    func load(account:String) throws -> Data? {
        var request=query(account);request[kSecReturnData as String]=true;request[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(request as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data else{throw NativeSessionStore.keychainFailure()}
        return data
    }
    func save(account:String,data:Data) throws {
        var request=query(account);request[kSecValueData as String]=data;request[kSecAttrLabel as String]="澄闻 · 音乐账号"
        guard SecItemAdd(request as CFDictionary,nil)==errSecSuccess else{throw NativeSessionStore.keychainFailure()}
    }
    func delete(account:String) throws {
        let status=SecItemDelete(query(account) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else{throw NativeSessionStore.keychainFailure()}
    }
}

actor NativeAccountGate {
    static let shared=NativeAccountGate()
    private var active=Set<String>()
    private var previous:[String:TimeInterval]=[:]
    private let now:@Sendable ()->TimeInterval
    init(now:@escaping @Sendable ()->TimeInterval={ProcessInfo.processInfo.systemUptime}) {self.now=now}
    func acquire(_ key:String) async throws {
        let deadline=now()+35
        while active.contains(key) {
            try Task.checkCancellation()
            guard now()<deadline else{throw EngineFailure(reason:"账号请求正在排队，请稍后重试。",code:"account_busy")}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        active.insert(key)
        do {
            if let previous=previous[key] {
                let delay=max(0,min(2,2-(now()-previous)))
                if delay>0 {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}
            }
            try Task.checkCancellation()
        } catch {active.remove(key);throw error}
    }
    func release(_ key:String){previous[key]=now();active.remove(key)}
}

struct NativeSessionStore {
    static let platforms=["netease","kuwo"]
    private static let metadataLock=NSRecursiveLock()
    // Keep a risk pause effective for this process even when its disk record
    // cannot be written. No cookies or credentials are retained here.
    private static var pendingBlocks:[String:[String:String]]=[:]
    let root:URL
    let vault:NativeSessionVault
    let api:NativeAccountAdapters.HTTP
    init(root:URL,vault:NativeSessionVault=NativeSystemSessionVault(),api:@escaping NativeAccountAdapters.HTTP=NativeAccountAdapters.liveHTTP) {
        self.root=root.resolvingSymlinksInPath();self.vault=vault;self.api=api
    }
    static func keychainFailure()->EngineFailure {EngineFailure(reason:"无法访问macOS钥匙串。",solution:"请解锁登录钥匙串并允许本次访问，然后重试。",code:"keychain")}
    static func auth(_ reason:String="登录状态已过期，请重新连接账号。",code:String="account_expired")->EngineFailure {EngineFailure(reason:reason,solution:"请在账号设置中打开官方登录窗口，完成登录后重新连接。",code:code)}
    static func revision(_ value:String)->Bool {value.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil}
    func synchronized<T>(_ body:()throws->T) rethrows -> T {Self.metadataLock.lock();defer{Self.metadataLock.unlock()};return try body()}
    private func blockKey(_ platform:String)->String {root.path+":"+platform}
    /// Public metadata only, no account file or Keychain access. The revision match
    /// prevents a stale pause from leaking into a newly connected account.
    static func inMemoryPauseCode(storeURL:URL,platform:String,revision:String)->String? {
        metadataLock.lock();defer{metadataLock.unlock()}
        guard platforms.contains(platform),Self.revision(revision),let block=pendingBlocks[storeURL.resolvingSymlinksInPath().path+":"+platform],block["revision"]==revision else{return nil}
        return block["code"]=="account_expired" ? "account_expired" : "account_risk"
    }
    func records()->[String:[String:Any]] {
        synchronized {
            let document=AppFiles.read("accounts.json",at:root) as? [String:Any] ?? [:]
            return document["schema"] as? Int==2 ? document["accounts"] as? [String:[String:Any]] ?? [:] : [:]
        }
    }
    func references()->[String:[String:Any]] {
        records().reduce(into:[:]){result,pair in
            guard Self.platforms.contains(pair.key),let revision=pair.value["revision"] as? String,Self.revision(revision) else{return}
            result[pair.key]=["store":root.path,"platform":pair.key,"revision":revision]
        }
    }
    private func epoch(_ platform:String)->String {
        let document=AppFiles.read("accounts.json",at:root) as? [String:Any] ?? [:]
        return (document["epochs"] as? [String:String])?[platform] ?? ""
    }
    private func writeRecords(_ accounts:[String:[String:Any]],revoking platform:String?=nil) throws {
        let previous=AppFiles.read("accounts.json",at:root) as? [String:Any] ?? [:]
        var epochs=previous["epochs"] as? [String:String] ?? [:]
        if let platform=platform{epochs[platform]=UUID().uuidString}
        try AppFiles.write(["schema":2,"accounts":accounts,"epochs":epochs],name:"accounts.json",at:root)
    }
    func publicResult(_ record:[String:Any]?=nil)->[String:Any] {
        synchronized {
            let keys:Set<String>=["revision","storage","nickname","verified","method","updated_at"]
            var value:[String:Any]=["records":records().filter{Self.platforms.contains($0.key)}.mapValues{$0.filter{keys.contains($0.key)}},"refs":references()]
            if let record=record {value["record"]=record.filter{keys.contains($0.key)}};return value
        }
    }
    func assertCurrent(_ ref:[String:Any]) throws {
        try synchronized {
            guard let platform=ref["platform"] as? String,Self.platforms.contains(platform),let revision=ref["revision"] as? String,Self.revision(revision),let path=ref["store"] as? String,URL(fileURLWithPath:path).resolvingSymlinksInPath().path==root.path,records()[platform]?["revision"] as? String==revision else{throw Self.auth("账号已退出或切换，本次任务的旧会话已停用。",code:"account_changed")}
            let blocks=AppFiles.read("account-blocks.json",at:root) as? [String:[String:Any]] ?? [:]
            let cached=Self.pendingBlocks[blockKey(platform)]
            if cached?["revision"]==revision || blocks[platform]?["revision"] as? String==revision {
                let reason=cached?["revision"]==revision ? cached?["code"] : blocks[platform]?["code"] as? String
                let code=reason=="account_expired" ? "account_expired" : "account_risk"
                throw Self.auth(code=="account_expired" ? "登录状态已过期，请重新连接账号。" : "平台要求额外验证，已暂停该账号的自动请求。",code:code)
            }
        }
    }
    static func validateReference(_ ref:[String:Any]) throws {
        guard let path=ref["store"] as? String,!path.isEmpty else{throw auth(code:"account_changed")}
        try NativeSessionStore(root:URL(fileURLWithPath:path)).assertCurrent(ref)
    }
    func key(_ platform:String,_ revision:String?=nil)->String {
        if let revision=revision{return NativeAccountValidation.candidateAccount(storeURL:root,platform:platform,revision:revision)}
        return NativeAccountValidation.candidateAccount(storeURL:root,platform:platform,revision:"").dropLast().description
    }
    func storedKey(_ platform:String,_ record:[String:Any])->String {key(platform,record["storage"] as? String=="revision" ? record["revision"] as? String : nil)}
    func load(_ ref:[String:Any]) throws -> [String:Any] {
        try Task.checkCancellation();try assertCurrent(ref)
        let platform=ref["platform"] as! String
        guard let data=try vault.load(account:storedKey(platform,records()[platform] ?? [:])),data.count<=1_048_576,let payload=try JSONSerialization.jsonObject(with:data) as? [String:Any],payload["revision"] as? String==ref["revision"] as? String else{throw Self.auth()}
        try assertCurrent(ref);return payload
    }
    func block(_ ref:[String:Any],code:String="account_risk") throws {
        try synchronized {
            guard let platform=ref["platform"] as? String,Self.platforms.contains(platform),let revision=ref["revision"] as? String,Self.revision(revision),let path=ref["store"] as? String,URL(fileURLWithPath:path).resolvingSymlinksInPath().path==root.path,records()[platform]?["revision"] as? String==revision else{return}
            Self.pendingBlocks[blockKey(platform)]=["revision":revision,"code":code]
            var blocks=AppFiles.read("account-blocks.json",at:root) as? [String:[String:Any]] ?? [:]
            blocks[platform]=["revision":revision,"code":code,"at":ISO8601DateFormatter().string(from:Date())]
            try AppFiles.write(blocks,name:"account-blocks.json",at:root)
            Self.pendingBlocks.removeValue(forKey:blockKey(platform))
        }
    }
    func withOperation<T>(_ platform:String,_ body:() async throws->T) async throws->T {
        let gateKey=root.path+":"+platform
        try await NativeAccountGate.shared.acquire(gateKey)
        do {let value=try await body();await NativeAccountGate.shared.release(gateKey);return value}
        catch {await NativeAccountGate.shared.release(gateKey);throw error}
    }
    func connect(_ platform:String,payload:[String:Any],profile:[String:Any],previous:[String:Any],expectedEpoch:String) throws -> [String:Any] {
        let revision=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),name=key(platform,revision)
        var committed=false
        defer{if !committed{try? vault.delete(account:name)}}
        try Task.checkCancellation()
        var secret=payload;secret["revision"]=revision
        try vault.save(account:name,data:JSONSerialization.data(withJSONObject:secret))
        let record:[String:Any]=["revision":revision,"storage":"revision","nickname":String((profile["nickname"] as? String ?? "已连接账号").prefix(60)),"verified":true,"method":"official_web","updated_at":ISO8601DateFormatter().string(from:Date())]
        try synchronized {
            try Task.checkCancellation()
            var all=records()
            guard all[platform]?["revision"] as? String==previous["revision"] as? String,epoch(platform)==expectedEpoch else{throw Self.auth("账号已退出或在其他窗口变化，请重新连接。",code:"account_changed")}
            all[platform]=record
            try writeRecords(all);committed=true
            Self.pendingBlocks.removeValue(forKey:blockKey(platform))
        }
        if previous["revision"] != nil {try? vault.delete(account:storedKey(platform,previous))}
        return record
    }
    func logout(_ platform:String) throws {
        let previous=try synchronized {()->[String:Any] in
            var all=records();let previous=all.removeValue(forKey:platform) ?? [:]
            try writeRecords(all,revoking:platform)
            Self.pendingBlocks.removeValue(forKey:blockKey(platform));return previous
        }
        if previous["revision"] != nil {try vault.delete(account:storedKey(platform,previous))}
    }
    static func perform(operation:String,payload:[String:Any]) async throws->[String:Any] {
        guard let path=payload["store"] as? String,!path.isEmpty else{throw EngineFailure(reason:"账号保存位置无效。",code:"invalid_request")}
        return try await NativeSessionStore(root:URL(fileURLWithPath:path)).perform(operation,payload:payload)
    }
    func perform(_ operation:String,payload:[String:Any]) async throws->[String:Any] {
        try Task.checkCancellation()
        if operation=="accounts" {return publicResult()}
        guard let platform=payload["platform"] as? String,Self.platforms.contains(platform) else{throw EngineFailure(reason:"当前版本只支持网易云音乐与酷我音乐账号。",code:"source_unsupported")}
        if operation=="account" {
            if payload["action"] as? String=="logout" {try logout(platform);return publicResult()}
            guard payload["action"] as? String=="check",let ref=references()[platform] else{throw Self.auth("请通过应用内官方登录窗口连接账号。")}
            return try await withOperation(platform) {
                let secret=try load(ref)
                _=try await NativeAccountAdapters.validate(platform,payload:secret,reference:ref,store:self)
                try assertCurrent(ref);return publicResult()
            }
        }
        guard operation=="activate_account",Set(payload.keys).isSubset(of:["store","platform","revision"]),let revision=payload["revision"] as? String,Self.revision(revision),records()[platform]?["revision"] as? String != revision else{throw EngineFailure(reason:"候选登录会话无效。",code:"invalid_request")}
        let candidate=key(platform,revision)
        // Capture before waiting: logout or another activation while queued
        // must invalidate this older intent instead of becoming its baseline.
        let (previous,expectedEpoch)=synchronized{(records()[platform] ?? [:],epoch(platform))}
        defer{try? vault.delete(account:candidate)}
        return try await withOperation(platform) {
            try synchronized {
                guard records()[platform]?["revision"] as? String==previous["revision"] as? String,epoch(platform)==expectedEpoch else{throw Self.auth("账号已退出或在其他窗口变化，请重新连接。",code:"account_changed")}
            }
            guard let data=try vault.load(account:candidate),data.count<=1_048_576,var secret=try JSONSerialization.jsonObject(with:data) as? [String:Any],secret["revision"] as? String==revision,let at=secret["staged_at"] as? NSNumber,(0...300).contains(Date().timeIntervalSince1970-at.doubleValue) else{throw Self.auth("本次网页登录确认已失效，请重新连接。")}
            secret["cookies"]=try NativeAccountAdapters.filteredCookies(secret["cookies"],platform:platform)
            _=try NativeAccountValidation.userAgent(secret["user_agent"])
            if platform=="netease" {
                var identity=secret["native_identity"] as? [String:Any] ?? [:];identity["userAgent"]=secret["user_agent"]
                guard identity["verified"] as? Bool==true else{throw Self.auth()}
                _=try NativeAccountValidation.neteaseIdentity(identity)
            }
            let profile=try await NativeAccountAdapters.validate(platform,payload:secret,reference:nil,store:self)
            let record=try connect(platform,payload:secret,profile:profile,previous:previous,expectedEpoch:expectedEpoch)
            return publicResult(record)
        }
    }
}
