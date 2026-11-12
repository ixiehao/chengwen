import Foundation

struct EngineFailure:Error {
    var code:String
    var reason:String
    var solution:String
    var technical:String
    init(_ data:[String:Any]) {code=data["code"] as? String ?? "engine";reason=data["reason"] as? String ?? "未完成音乐请求。";solution=data["solution"] as? String ?? "请检查网络和运行环境后重试。";technical=data["technical"] as? String ?? ""}
    init(reason:String,solution:String="请检查网络和运行环境后重试。",code:String="engine") {self.code=code;self.reason=reason;self.solution=solution;self.technical=""}
}
final class EngineTask:@unchecked Sendable {
    private let lock=NSLock()
    private var task:Task<Void,Never>?
    private var cancelled=false
    private var completionDelivered=false
    var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
    var acceptsEvents:Bool {lock.lock();defer{lock.unlock()};return !cancelled && !completionDelivered}
    func markCompleted(){lock.lock();completionDelivered=true;lock.unlock()}
    func install(_ value:Task<Void,Never>){lock.lock();task=value;let cancel=cancelled;lock.unlock();if cancel{value.cancel()}}
    func cancel(){lock.lock();cancelled=true;let value=task;lock.unlock();value?.cancel()}
}
final class BackendClient:@unchecked Sendable {
    typealias Execute=(String,[String:Any],@escaping(String,[String:Any])->Void) async throws->[String:Any]
    private let execute:Execute
    private let lifecycleLock=NSLock()
    private var tasks:[UUID:EngineTask]=[:]
    private var acceptingRequests=true
    private let work=DispatchGroup()
    private func finished(_ identifier:UUID) {
        lifecycleLock.lock();tasks.removeValue(forKey:identifier);lifecycleLock.unlock();work.leave()
    }
    init(execute:@escaping Execute=NativeMusicEngine.execute){self.execute=execute}
    @discardableResult func request(_ operation:String,payload:[String:Any],onEvent:((String,[String:Any])->Void)?=nil,completion:@escaping(Result<[String:Any],EngineFailure>)->Void)->EngineTask {
        let identifier=UUID(),token=EngineTask()
        lifecycleLock.lock()
        guard acceptingRequests else {
            lifecycleLock.unlock();token.cancel()
            DispatchQueue.main.async{token.markCompleted();completion(.failure(EngineFailure(reason:"应用正在退出。",solution:"",code:"cancelled")))}
            return token
        }
        tasks[identifier]=token;work.enter();lifecycleLock.unlock()
        token.install(Task.detached(priority:.userInitiated){
            defer {
                self.finished(identifier)
            }
            let result:Result<[String:Any],EngineFailure>
            do {
                try Task.checkCancellation()
                let value=try await self.execute(operation,payload){event,data in
                    DispatchQueue.main.async{if token.acceptsEvents{onEvent?(event,data)}}
                }
                // Preserve successful atomic commits despite a later cancel.
                result = .success(value)
            } catch is CancellationError {result = .failure(EngineFailure(reason:"已取消。",solution:"",code:"cancelled"))}
            catch let failure as EngineFailure {result = .failure(failure)}
            catch let failure as NativeAccountProblem {result = .failure(EngineFailure(reason:failure.reason,solution:failure.solution,code:"account_response"))}
            catch {
                let error=error as NSError
                if Task.isCancelled || (error.domain==NSURLErrorDomain && error.code==NSURLErrorCancelled) {result = .failure(EngineFailure(reason:"已取消。",solution:"",code:"cancelled"))}
                else if error.domain==NSURLErrorDomain {
                    result = .failure(EngineFailure(reason:error.code==NSURLErrorTimedOut ? "连接音源超时。" : "无法连接当前音源。",solution:"请检查网络后重试，仍失败可换其他来源。",code:"network"))
                } else if error.domain==NSCocoaErrorDomain,[NSFileWriteNoPermissionError,NSFileWriteOutOfSpaceError,NSFileReadNoPermissionError,NSFileWriteVolumeReadOnlyError].contains(error.code) {
                    result = .failure(EngineFailure(reason:error.code==NSFileWriteOutOfSpaceError ? "保存位置的磁盘空间不足。" : "没有权限访问保存位置。",solution:"请选择可写且空间充足的保存目录后重试。",code:"filesystem"))
                } else {result = .failure(EngineFailure(reason:"音乐请求未能完成。",solution:"请检查网络和运行环境，或换其他来源后重试。"))}
            }
            // Mark on the same queue as event delivery. Progress already queued
            // before this result is preserved; saved callbacks arriving after
            // completion cannot reactivate a finished request.
            DispatchQueue.main.async{token.markCompleted();completion(result)}
        })
        return token
    }
    func shutdown(completion:@escaping()->Void) {
        lifecycleLock.lock();acceptingRequests=false;let current=Array(tasks.values);lifecycleLock.unlock()
        current.forEach{$0.cancel()}
        work.notify(queue:.global(qos:.userInitiated),execute:completion)
    }
}
