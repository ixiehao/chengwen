import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import SwiftUI
import WebKit

private let nativeAccountCandidateQueue = DispatchQueue(label: "local.chengwen.native-account-candidates", qos: .userInitiated)

// Only candidate sessions created by this window use these methods. The active
// account slot belongs to NativeSessionStore and is never deleted by the UI.
protocol NativeAccountVault: Sendable {
    func stage(account: String, data: Data) -> OSStatus
    func remove(account: String)
}

struct NativeSystemAccountVault: NativeAccountVault {
    // Immutable vault identity retained for existing user sessions after renaming.
    static let service = "local.vmdown.accounts.v2"

    func stage(account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "澄闻 · 待验证会话",
            kSecValueData as String: data,
        ]
        // Use the same macOS Keychain service as active versioned sessions.
        return SecItemAdd(query as CFDictionary, nil)
    }

    func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct NativeAccountIdentity {
    let code: Int
    let origin: String
    let uid: String
    let profileUID: String
    let nickname: String
    let userAgent: String

    var payload: [String: Any] {
        ["code": code, "origin": origin, "uid": uid, "profile_uid": profileUID,
         "nickname": nickname, "verified": true]
    }
}

struct NativeAccountProblem: Error {
    let reason: String
    let solution: String
}

enum NativeAccountValidation {
    static func userAgent(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty,
              value.utf8.count <= 1024, !value.utf8.contains(13), !value.utf8.contains(10) else {
            throw NativeAccountProblem(reason: "未能确认网页的浏览器信息。", solution: "请重新加载官方登录页后再连接。")
        }
        return value
    }

    static func neteaseIdentity(_ data: [String: Any]) throws -> NativeAccountIdentity {
        let code = (data["code"] as? NSNumber)?.doubleValue
        let uid = data["uid"] as? String ?? ""
        let profileUID = data["profile_uid"] as? String ?? ""
        let origin = data["origin"] as? String ?? ""
        guard code == 200, !uid.isEmpty, uid.count <= 32, uid.contains(where: { $0 != "0" }), uid == profileUID,
              uid.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              origin == "https://music.163.com" else {
            throw NativeAccountProblem(reason: "尚未确认网易云账号登录成功。", solution: "请先在网页中完成登录，再点击「完成登录并连接」。")
        }
        return NativeAccountIdentity(code: 200, origin: origin, uid: uid, profileUID: profileUID,
                                     nickname: String((data["nickname"] as? String ?? "网易云用户").prefix(60)),
                                     userAgent: try userAgent(data["userAgent"]))
    }

    static func allowsMainURL(_ url: URL, platform: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        guard ["netease", "kuwo"].contains(platform) else { return false }
        let domain = platform == "netease" ? "163.com" : "kuwo.cn"
        return host == domain || host.hasSuffix("." + domain)
    }

    static func cookieRecords(_ cookies: [HTTPCookie], platform: String, now: Date = Date()) -> [[String: Any]] {
        cookies.compactMap { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let allowed: Bool
            if platform == "netease" {
                allowed = domain == "music.163.com" || domain.hasSuffix(".music.163.com") ||
                    (domain == "163.com" && ["MUSIC_U", "__csrf"].contains(cookie.name))
            } else if platform == "kuwo" {
                allowed = domain == "kuwo.cn" || domain.hasSuffix(".kuwo.cn")
            } else {
                allowed = false
            }
            guard allowed, !cookie.value.isEmpty,
                  cookie.expiresDate == nil || cookie.expiresDate! > now else { return nil }
            return ["name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                    "path": cookie.path, "secure": cookie.isSecure,
                    "expires": cookie.expiresDate.map { Int($0.timeIntervalSince1970) } as Any? ?? NSNull(),
                    "rest": ["HttpOnly": cookie.isHTTPOnly]]
        }
    }

    static func candidateAccount(storeURL: URL, platform: String, revision: String) -> String {
        let path = storeURL.resolvingSymlinksInPath().path
        let scope = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        return "\(scope):\(platform):\(revision)"
    }
}

typealias NativeAccountCancel = @MainActor () -> Void
typealias NativeAccountRequest = @MainActor (
    _ operation: String,
    _ payload: [String: Any],
    _ onEvent: ((String, [String: Any]) -> Void)?,
    _ completion: @escaping (Result<[String: Any], EngineFailure>) -> Void
) -> NativeAccountCancel

enum NativeAccountMode { case web }

struct NativeOwnedAccountSession {
    let identityResponse: [String: Any]
    let cookies: [HTTPCookie]
}

typealias NativeOwnedSessionReader = @MainActor (
    _ completion: @escaping (Result<NativeOwnedAccountSession, NativeAccountProblem>) -> Void
) -> Void

@MainActor
final class NativeAccountViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let platform: String
    let storeURL: URL
    let name: String
    let webView: WKWebView?
    @Published private(set) var mode: NativeAccountMode
    @Published private(set) var isBusy = false
    @Published private(set) var isWebLoading = false
    @Published private(set) var reason = ""
    @Published private(set) var solution = ""
    var requestClose: (() -> Void)?

    private let request: NativeAccountRequest
    private let vault: NativeAccountVault
    private let vaultQueue = nativeAccountCandidateQueue
    private let onChange: () -> Void
    private let autoLoadWeb: Bool
    private let ownedSessionReader: NativeOwnedSessionReader?
    private let kuwoDevice: [String: String]
    private var cancelOperation: NativeAccountCancel?
    private var candidateAccounts = Set<String>()
    private var generation = UUID()
    private var closed = false
    private var didLoad = false
    private var didNotify = false
    private var clearingWebPage = false

    init(platform: String, storeURL: URL, request: @escaping NativeAccountRequest,
         vault: NativeAccountVault = NativeSystemAccountVault(), autoLoadWeb: Bool = true,
         ownedSessionReader: NativeOwnedSessionReader? = nil,
         onChange: @escaping () -> Void) {
        self.platform = platform
        self.storeURL = storeURL.resolvingSymlinksInPath()
        self.name = ["netease": "网易云音乐", "kuwo": "酷我音乐"][platform] ?? platform
        self.mode = .web
        self.request = request
        self.vault = vault
        self.autoLoadWeb = autoLoadWeb
        self.ownedSessionReader = ownedSessionReader
        self.onChange = onChange
        self.kuwoDevice = ["id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                           "user": String(UInt64.random(in: 1_000_000_000..<2_000_000_000))]
        if (platform == "netease" || platform == "kuwo") && ownedSessionReader == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            self.webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            self.webView = nil
        }
        super.init()
        webView?.navigationDelegate = self
        webView?.uiDelegate = self
    }

    var iconName: String { platform == "netease" ? "music" : "headphones" }
    var officialURL: URL {
        URL(string: platform == "netease" ? "https://music.163.com/#/login" :
              "https://www.kuwo.cn/?login=open")!
    }

    func startInitialLoading() {
        guard !didLoad, !closed else { return }
        didLoad = true
        if autoLoadWeb && mode == .web { reloadOfficialPage() }
    }

    func reloadOfficialPage() {
        guard !closed, !isBusy, let webView = webView else { return }
        reason = ""
        solution = ""
        clearingWebPage = false
        isWebLoading = true
        webView.load(URLRequest(url: officialURL))
    }

    private func beginOperation() -> UUID {
        generation = UUID()
        didNotify = false
        isBusy = true
        reason = ""
        solution = ""
        return generation
    }

    private func current(_ operation: UUID) -> Bool { !closed && generation == operation }

    func connectOwnedWebSession() {
        guard !closed, !isBusy, mode == .web else { return }
        let operation = beginOperation()
        reason = "正在确认官方网页登录状态…"
        // A fake reader + in-memory vault can exercise the full activation
        // state machine without constructing WebKit or touching Keychain.
        if let reader = ownedSessionReader {
            reader { [weak self] result in
                guard let self = self, self.current(operation) else { return }
                switch result {
                case .success(let session):
                    do {
                        let (userAgent, identity) = try self.validateIdentityResponse(session.identityResponse)
                        self.consumeOwnedCookies(session.cookies, operation: operation, userAgent: userAgent, identity: identity)
                    } catch let problem as NativeAccountProblem {
                        self.fail(problem.reason, solution: problem.solution)
                    } catch {
                        self.fail("未能确认官方网页登录状态。", solution: "请完成网页登录后再连接。")
                    }
                case .failure(let problem): self.fail(problem.reason, solution: problem.solution)
                }
            }
            return
        }
        guard let webView = webView else {
            fail("官方登录页尚未准备好。", solution: "请重新打开账号登录窗口。")
            return
        }
        let script: String
        if platform == "netease" {
            script = """
            if (location.origin !== 'https://music.163.com') {
                return {code: 0, origin: location.origin};
            }
            const response = await fetch('/api/w/nuser/account/get?timestamp=' + Date.now(), {
                method: 'GET', credentials: 'include', cache: 'no-store'
            });
            const data = await response.json();
            return {
                code: data.code,
                uid: data.account && data.account.id != null ? String(data.account.id) : '',
                profile_uid: data.profile && data.profile.userId != null ? String(data.profile.userId) : '',
                nickname: data.profile && typeof data.profile.nickname === 'string' ? data.profile.nickname : '',
                userAgent: navigator.userAgent,
                origin: location.origin
            };
            """
        } else {
            script = "return {origin: location.origin, userAgent: navigator.userAgent};"
        }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: { [weak self] result in
            guard let self = self, self.current(operation) else { return }
            do {
                guard case .success(let value) = result, let data = value as? [String: Any] else {
                    throw NativeAccountProblem(reason: "未能确认官方网页登录状态。", solution: "请完成网页中的登录或验证码，再点击连接。")
                }
                let (userAgent, identity) = try self.validateIdentityResponse(data)
                self.readOwnedCookies(operation: operation, userAgent: userAgent, identity: identity)
            } catch let problem as NativeAccountProblem {
                self.fail(problem.reason, solution: problem.solution)
            } catch {
                self.fail("未能确认官方网页登录状态。", solution: "请完成官方网页登录后重试。")
            }
        })
    }

    private func validateIdentityResponse(_ data: [String: Any]) throws -> (String, NativeAccountIdentity?) {
        if platform == "netease" {
            let identity = try NativeAccountValidation.neteaseIdentity(data)
            return (identity.userAgent, identity)
        }
        guard let origin = data["origin"] as? String, let url = URL(string: origin),
              NativeAccountValidation.allowsMainURL(url, platform: "kuwo") else {
            throw NativeAccountProblem(reason: "请先返回酷我官方登录页。", solution: "重新加载官方页面，完成登录后再连接。")
        }
        return (try NativeAccountValidation.userAgent(data["userAgent"]), nil)
    }

    private func readOwnedCookies(operation: UUID, userAgent: String, identity: NativeAccountIdentity?) {
        guard current(operation), let webView = webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self = self, self.current(operation) else { return }
                self.consumeOwnedCookies(cookies, operation: operation, userAgent: userAgent, identity: identity)
            }
        }
    }

    private func consumeOwnedCookies(_ cookies: [HTTPCookie], operation: UUID, userAgent: String, identity: NativeAccountIdentity?) {
        guard current(operation) else { return }
        let records = NativeAccountValidation.cookieRecords(cookies, platform: platform)
        if records.isEmpty || (platform == "netease" && !records.contains { ($0["name"] as? String) == "MUSIC_U" }) {
            fail("尚未取得当前平台的有效登录会话。", solution: "请先在网页中完成登录，再点击连接；验证码受限时请使用官方客户端。")
            return
        }
        stage(records: records, userAgent: userAgent, identity: identity, operation: operation)
    }

    private func stage(records: [[String: Any]], userAgent: String, identity: NativeAccountIdentity?, operation: UUID) {
        let revision = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let account = NativeAccountValidation.candidateAccount(storeURL: storeURL, platform: platform, revision: revision)
        let stagedAt = Date()
        var payload: [String: Any] = ["cookies": records, "user_agent": userAgent, "revision": revision,
                                      "staged_at": Int(stagedAt.timeIntervalSince1970)]
        if let identity = identity { payload["native_identity"] = identity.payload }
        if platform == "kuwo" { payload["device"] = kuwoDevice }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
            guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        } catch {
            fail("会话数据无法安全保存。", solution: "请重新加载官方页面后再连接。")
            return
        }
        candidateAccounts.insert(account)
        reason = "正在将候选会话保存到 macOS 钥匙串…"
        let vault = self.vault
        vaultQueue.async { [weak self] in
            let status = vault.stage(account: account, data: data)
            DispatchQueue.main.async {
                guard let self = self else {
                    nativeAccountCandidateQueue.async { vault.remove(account: account) }
                    return
                }
                guard self.current(operation) else {
                    self.cleanupCandidate(account)
                    return
                }
                guard status == errSecSuccess else {
                    self.cleanupCandidate(account)
                    self.fail(status == errSecUserCanceled ? "钥匙串保存已取消。" : "未能把会话保存到 macOS 钥匙串。",
                              solution: "请解锁登录钥匙串并允许本次保存，再点击连接。")
                    return
                }
                guard (0...300).contains(Date().timeIntervalSince(stagedAt)) else {
                    self.cleanupCandidate(account)
                    self.fail("本次会话确认已超过有效时间。", solution: "请再次点击完成登录并连接，以重新确认当前登录状态。")
                    return
                }
                self.activate(revision: revision, candidate: account, operation: operation)
            }
        }
    }

    private func activate(revision: String, candidate: String, operation: UUID) {
        guard current(operation) else { cleanupCandidate(candidate); return }
        reason = "正在验证会话和平台权限…"
        cancelOperation = request("activate_account", ["store": storeURL.path, "platform": platform, "revision": revision], nil) { [weak self] result in
            guard let self = self else { return }
            self.cleanupCandidate(candidate)
            guard self.current(operation) else {
                self.onChange()
                return
            }
            self.cancelOperation = nil
            switch result {
            case .success:
                self.isBusy = false
                self.notifyChange()
                self.requestClose?()
            case .failure(let error):
                self.fail(error.reason, solution: error.solution)
            }
        }
    }

    private func cleanupCandidate(_ account: String) {
        candidateAccounts.remove(account)
        let vault = self.vault
        vaultQueue.async { vault.remove(account: account) }
    }

    private func cleanupAllCandidates() {
        let accounts = candidateAccounts
        candidateAccounts.removeAll()
        let vault = self.vault
        vaultQueue.async { accounts.forEach { vault.remove(account: $0) } }
    }

    private func notifyChange() {
        guard !didNotify else { return }
        didNotify = true
        onChange()
    }

    private func fail(_ reason: String, solution: String) {
        guard !closed else { return }
        cancelOperation = nil
        isBusy = false
        self.reason = reason
        self.solution = solution
        cleanupAllCandidates()
        notifyChange()
    }

    func close() {
        guard !closed else { return }
        closed = true
        generation = UUID()
        cancelOperation?()
        cancelOperation = nil
        cleanupAllCandidates()
        clearWebPage()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        notifyChange()
    }

    func finishCandidateCleanup(_ completion: @escaping () -> Void) {
        close()
        vaultQueue.async { DispatchQueue.main.async(execute: completion) }
    }

    private func clearWebPage() {
        clearingWebPage = true
        isWebLoading = false
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if clearingWebPage && url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            // Official login pages may host HTTPS verification frames on
            // separate captcha domains; they cannot replace the main origin.
            decisionHandler(url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        guard NativeAccountValidation.allowsMainURL(url, platform: platform) else {
            reason = "已阻止登录页跳转到当前平台之外的网站。"
            solution = "请在当前官方窗口完成验证；受限时请使用官方客户端。"
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !closed, !clearingWebPage else { return }
        isWebLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isWebLoading = false }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }

    private func navigationFailed(_ error: Error) {
        guard !closed, !clearingWebPage, (error as NSError).code != NSURLErrorCancelled else { return }
        isWebLoading = false
        reason = "官方登录页未能加载。"
        solution = "请检查网络后重新加载官方页面。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        isWebLoading = false
        reason = "登录网页进程已停止。"
        solution = "请点击重新加载官方页面。"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

private struct OwnedAccountWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct NativeAccountConnectionView: View {
    @ObservedObject var model: NativeAccountViewModel
    var body:some View {
        // WKWebView's current frame is not an ideal window size. Give the
        // content the actual available bounds so hosting cannot feed that
        // frame back into an ever taller window on macOS 12 and later.
        GeometryReader { bounds in
            content.frame(width:bounds.size.width,height:bounds.size.height)
        }.background(Color(nsColor:.windowBackgroundColor))
            .onAppear(perform:model.startInitialLoading)
    }
    private var content:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                TablerIcon(name:model.iconName,size:20).foregroundColor(.accentColor)
                Text("连接\(model.name)").font(.system(size:17,weight:.semibold))
                Spacer()
                if model.isWebLoading {
                    ProgressView().controlSize(.small)
                    Text("正在打开官方网页…").font(.system(size:11)).foregroundColor(.secondary)
                }
                Button(action:model.reloadOfficialPage){HStack(spacing:5){TablerIcon(name:"refresh",size:14);Text("重新加载")}}
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy)
                    .help("重新载入平台的官方登录网页")
            }
            Text("在下方官方网页完成登录，再点击「完成登录并连接」。").font(.system(size:12)).foregroundColor(.secondary)
            if let webView=model.webView {
                ZStack {
                    OwnedAccountWebView(webView:webView).allowsHitTesting(!model.isBusy)
                    if model.isBusy {Color(nsColor:.windowBackgroundColor).opacity(0.78);ProgressView().controlSize(.small)}
                }.frame(minWidth:700,minHeight:220,maxHeight:.infinity)
                    .clipShape(RoundedRectangle(cornerRadius:6))
                    .overlay(RoundedRectangle(cornerRadius:6).stroke(Color(nsColor:.separatorColor),lineWidth:0.5))
            }
            if !model.reason.isEmpty {
                GroupBox {
                    ScrollView {
                        VStack(alignment:.leading,spacing:5) {
                            HStack(spacing:7){if model.isBusy{ProgressView().controlSize(.small)};Text(model.reason).font(.system(size:12,weight:.medium))}
                            if !model.solution.isEmpty{Text(model.solution).font(.system(size:12)).foregroundColor(.secondary)}
                        }.fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).padding(5)
                    }.frame(height:72)
                }
            }
            Text("会话仅保存在本机macOS钥匙串。平台可能限制第三方访问，登录不代表所有歌曲都有下载权益。").font(.system(size:11)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            HStack {
                Spacer()
                Button("取消"){model.requestClose?()}.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button("完成登录并连接",action:model.connectOwnedWebSession).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isBusy)
            }.controlSize(.regular)
        }.padding(.horizontal,20).padding(.top,42).padding(.bottom,16)
    }
}

@MainActor
private final class NativeAccountWindowController: NSWindowController, NSWindowDelegate {
    let model: NativeAccountViewModel
    private let onClosed: () -> Void

    init(model: NativeAccountViewModel, onClosed: @escaping () -> Void) {
        self.model = model
        self.onClosed = onClosed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(model.name) · 账号连接"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentMinSize = NSSize(width: 800, height: 660)
        window.contentView = NSHostingView(rootView: NativeAccountConnectionView(model: model))
        window.setContentSize(NSSize(width: 1000, height: 740))
        window.center()
        model.requestClose = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        model.close()
        onClosed()
    }
}

@MainActor
enum NativeAccounts {
    private static var windows: [UUID: NativeAccountWindowController] = [:]

    static func open(platform: String, storeURL: URL, engine: BackendClient, onChange: @escaping () -> Void) {
        guard ["netease", "kuwo"].contains(platform) else { return }
        let request: NativeAccountRequest = { operation, payload, event, completion in
            let task = engine.request(operation, payload: payload, onEvent: event, completion: completion)
            return { task.cancel() }
        }
        let model = NativeAccountViewModel(platform: platform, storeURL: storeURL, request: request, onChange: onChange)
        let identifier = UUID()
        let controller = NativeAccountWindowController(model: model) { windows.removeValue(forKey: identifier) }
        windows[identifier] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Use from applicationShouldTerminate with terminateLater, so a normal
    /// app quit also waits for pending Keychain writes followed by deletions.
    static func prepareForTermination(_ completion: @escaping @Sendable () -> Void) {
        let controllers = Array(windows.values)
        for controller in controllers {
            controller.model.close()
            controller.window?.close()
        }
        // Includes cleanup queued by account windows that were already closed
        // and removed from `windows` just before the user chose Quit.
        // terminateLater may be waiting in AppKit's nested event loop while
        // the main dispatch queue is already executing the Quit action.
        // A run-loop block can complete that handshake without queue reentry.
        nativeAccountCandidateQueue.async { RunLoop.main.perform(inModes:[.common],block:completion) }
    }
}
