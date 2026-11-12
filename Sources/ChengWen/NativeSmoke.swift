import AppKit
import WebKit

@MainActor enum NativeSmoke {
    private static var retained:NativeSmokeRun?
    static func run(model:AppModel,window:NSWindow,completion:@escaping(Bool)->Void) {
        retained=NativeSmokeRun(model:model,window:window,completion:completion)
        retained?.start()
    }
}
@MainActor final class NativeSmokeRun:NSObject,WKNavigationDelegate {
    let model:AppModel
    let window:NSWindow
    let completion:(Bool)->Void
    let web:WKWebView
    var task:EngineTask?
    var report:[String:Any]=["native_ui":true,"pure_swift":true,"frontend":"SwiftUI+AppKit"]
    var engineDone=false
    var webDone=false
    var failed=false
    var finished=false
    init(model:AppModel,window:NSWindow,completion:@escaping(Bool)->Void) {
        self.model=model;self.window=window;self.completion=completion
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        web=WKWebView(frame:NSRect(x:0,y:0,width:400,height:200),configuration:config)
        super.init();web.navigationDelegate=self
    }
    func start() {
        model.keyword="Native smoke"
        model.settings.recent=["Synthetic history","Second search"]
        model.tracks=[AudioTrack(raw:["id":"one","title":"Synthetic track","artist":"ChengWen","source":"netease","duration":"3:12","ext":"mp3"]),AudioTrack(raw:["id":"two","title":"Synthetic clip","artist":"ChengWen","source":"kuwo","duration":"0:18","ext":"mp3"])]
        model.selection=["one"]
        guard model.partiallySelected else{finish(false);return}
        model.toggleAll();guard model.allSelected else{finish(false);return}
        model.toggleAll();guard model.selection.isEmpty,model.tracks[1].fragment else{finish(false);return}
        report["selection_and_fragments"]=true
        task=model.engine.request("selftest",payload:[:]){result in
            switch result {
            case .success(let data):self.report["backend"]=data;self.engineDone=true;self.failed = data["passed"] as? Bool != true
            case .failure(let error):self.report["backend_error"]=error.reason;self.engineDone=true;self.failed=true
            }
            self.poll()
        }
        web.loadHTMLString("<html><body><script>window.nativeIdentity={origin:'https://music.163.com',code:200,uid:'123',profile_uid:'123',nickname:'Synthetic',userAgent:navigator.userAgent};</script>ChengWen synthetic WebKit check</body></html>",baseURL:URL(string:"https://music.163.com/"))
        DispatchQueue.main.asyncAfter(deadline:.now()+45){if !self.finished{self.report["timeout"]=true;self.finish(false)}}
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        webView.callAsyncJavaScript("return JSON.stringify(await Promise.resolve(window.nativeIdentity));",arguments:[:],in:nil,in:.page,completionHandler:{result in
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    guard let text=value as? String,let data=text.data(using:.utf8),let identity=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{self.failed=true;self.webDone=true;self.poll();return}
                    do {_=try NativeAccountValidation.neteaseIdentity(identity)} catch{self.failed=true}
                    let cookie=HTTPCookie(properties:[.name:"MUSIC_U",.value:"synthetic-native-qa-only",.domain:".music.163.com",.path:"/",.secure:"TRUE"])!
                    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie){
                        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies{cookies in
                            DispatchQueue.main.async {
                                self.webDone=true
                                self.report["native_webkit"]=NativeAccountValidation.cookieRecords(cookies,platform:"netease").count==1
                                if self.report["native_webkit"] as? Bool != true{self.failed=true}
                                self.poll()
                            }
                        }
                    }
                case .failure:self.failed=true;self.webDone=true;self.poll()
                }
            }
        })
    }
    func poll() {
        guard !finished,engineDone,webDone else{return}
        if model.isCheckingEnvironment {DispatchQueue.main.asyncAfter(deadline:.now()+0.1){self.poll()};return}
        report["environment_items"]=model.healthItems.count
        failed = failed || model.healthItems.isEmpty
        finish(!failed)
    }
    func finish(_ success:Bool) {
        guard !finished else{return};finished=true
        report["passed"]=success
        if let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys),let text=String(data:data,encoding:.utf8){print(text)}
        task?.cancel();web.stopLoading();web.navigationDelegate=nil;model.shutdown()
        completion(success)
    }
}
