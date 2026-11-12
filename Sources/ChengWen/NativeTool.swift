import Foundation
import Darwin

enum NativeTool {
    static func find(_ name:String) -> String? {
        let root=AppFiles.root().appendingPathComponent("bin").path
        var folders=[root,"/opt/homebrew/bin","/usr/local/bin","/opt/local/bin","/usr/bin"]
        folders += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)
        for folder in folders {
            let path=(folder as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath:path) {return path}
        }
        return nil
    }
    static func ffprobe() -> String? {
        guard let ffmpeg=find("ffmpeg") else{return nil}
        let path=(ffmpeg as NSString).deletingLastPathComponent+"/ffprobe"
        return FileManager.default.isExecutableFile(atPath:path) ? path : nil
    }
    static func run(_ executable:String,_ arguments:[String],timeout:TimeInterval=30) async throws -> Data {
        guard timeout.isFinite,timeout>0,timeout<=86400,!executable.utf8.contains(0),!arguments.contains(where:{$0.utf8.contains(0)}) else {
            throw EngineFailure(reason:"音频工具请求参数无效。",code:"invalid_request")
        }
        let run=NativeToolRun(executable,arguments,timeout:timeout)
        return try await withTaskCancellationHandler(operation:{try await run.start()},onCancel:{run.cancel()})
    }
}

private final class NativeToolRun: @unchecked Sendable {
    private let executable:String,arguments:[String],timeout:TimeInterval
    private let lock=NSLock()
    private var cancelled=false
    init(_ executable:String,_ arguments:[String],timeout:TimeInterval) {
        self.executable=executable;self.arguments=arguments;self.timeout=timeout
    }
    private var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
    func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.utility).async { [self] in
                do {continuation.resume(returning:try execute())}
                catch {continuation.resume(throwing:error)}
            }
        }
    }
    private static func launchFailure()->EngineFailure {
        EngineFailure(reason:"无法启动音频工具。",solution:"请在运行环境测试中检查FFmpeg/FFprobe的系统与芯片兼容性。",code:"tool_launch")
    }
    private static func groupMayRemain(_ pid:pid_t)->Bool {
        // An exiting group can briefly yield EPERM while its last member is
        // being reaped. Re-probe instead of converting that race into a false
        // failed conversion, but never treat persistent denial as success.
        for _ in 0..<5 {
            if kill(-pid,0)==0{return true}
            if errno==ESRCH{return false}
            if errno != EPERM{return true}
            usleep(10_000)
        }
        return true
    }
    private func execute() throws -> Data {
        guard !isCancelled else{throw CancellationError()}
        var descriptors=[Int32](repeating:0,count:2)
        guard pipe(&descriptors)==0 else{throw Self.launchFailure()}
        // Keep private endpoints outside 0/1/2 even if the GUI was launched
        // without standard descriptors, so file actions cannot close a map.
        let input=fcntl(descriptors[0],F_DUPFD_CLOEXEC,3),output=fcntl(descriptors[1],F_DUPFD_CLOEXEC,3)
        close(descriptors[0]);close(descriptors[1])
        guard input>=0,output>=0 else {
            if input>=0{close(input)};if output>=0{close(output)}
            throw Self.launchFailure()
        }
        defer{close(input)}
        var writeEndOpen=true
        defer{if writeEndOpen{close(output)}}
        guard fcntl(input,F_SETFL,fcntl(input,F_GETFL)|O_NONBLOCK)>=0,
              fcntl(input,F_SETFD,FD_CLOEXEC)>=0,fcntl(output,F_SETFD,FD_CLOEXEC)>=0 else{throw Self.launchFailure()}
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions)==0 else{throw Self.launchFailure()}
        defer{posix_spawn_file_actions_destroy(&actions)}
        guard posix_spawnattr_init(&attributes)==0 else{throw Self.launchFailure()}
        defer{posix_spawnattr_destroy(&attributes)}
        var mask=sigset_t(),defaults=sigset_t()
        sigemptyset(&mask);sigemptyset(&defaults)
        for number in [SIGTERM,SIGINT,SIGHUP,SIGQUIT,SIGPIPE,SIGCHLD] {sigaddset(&defaults,number)}
        let setup=[
            posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0),
            posix_spawn_file_actions_adddup2(&actions,output,STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions,output,STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions,input),
            posix_spawn_file_actions_addclose(&actions,output),
            posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes,0),
            posix_spawnattr_setsigmask(&attributes,&mask),
            posix_spawnattr_setsigdefault(&attributes,&defaults),
        ]
        guard setup.allSatisfy({$0==0}) else{throw Self.launchFailure()}
        var environment=ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("PYTHON") {environment.removeValue(forKey:key)}
        let argv=([executable]+arguments).map{strdup($0)}+[nil]
        let envp=environment.sorted{$0.key<$1.key}.map{strdup($0.key+"="+$0.value)}+[nil]
        defer{argv.forEach{free($0)};envp.forEach{free($0)}}
        guard argv.dropLast().allSatisfy({$0 != nil}),envp.dropLast().allSatisfy({$0 != nil}) else{throw Self.launchFailure()}
        var pid:pid_t=0
        let launched=argv.withUnsafeBufferPointer{arguments in
            envp.withUnsafeBufferPointer{environment in
                posix_spawn(&pid,executable,&actions,&attributes,UnsafeMutablePointer(mutating:arguments.baseAddress!),UnsafeMutablePointer(mutating:environment.baseAddress!))
            }
        }
        guard launched==0 else{throw Self.launchFailure()}
        close(output);writeEndOpen=false
        // The child is explicitly its own process-group leader. Timeout and
        // cancellation still own that group when the direct child exits but a
        // descendant holds stdout. Never signal the application's own group.
        var bytes=Data(),buffer=[UInt8](repeating:0,count:65536),status:Int32=0
        var reaped=false,eof=false,failure:Error?,terminationAt:TimeInterval?,killed=false
        let clock=ProcessInfo.processInfo,start=clock.systemUptime
        while !reaped || !eof {
            let now=clock.systemUptime
            if failure==nil {
                if isCancelled {failure=CancellationError()}
                else if now-start>=timeout {failure=EngineFailure(reason:"音频工具处理超时。",solution:"请检查工具状态或更换版本后重试。",code:"tool_timeout")}
            }
            if failure != nil,terminationAt==nil {kill(-pid,SIGTERM);terminationAt=now}
            if let at=terminationAt,!killed,now-at>=2 {kill(-pid,SIGKILL);killed=true}
            if !eof {
                let count=read(input,&buffer,buffer.count)
                if count>0,failure==nil {
                    if count<=2_000_000-bytes.count {bytes.append(contentsOf:buffer.prefix(count))}
                    else {failure=EngineFailure(reason:"音频工具返回内容过多，已停止处理。",solution:"请检查音频工具版本与输入文件后重试。",code:"tool_output")}
                } else if count==0 {eof=true}
                else if count<0,errno != EAGAIN,errno != EINTR {
                    eof=true
                    if failure==nil {failure=EngineFailure(reason:"无法读取音频工具的输出。",code:"tool_output")}
                }
            }
            if !reaped {
                let result=waitpid(pid,&status,WNOHANG)
                if result==pid {reaped=true}
                else if result<0,errno != EINTR {
                    reaped=true
                    if failure==nil {failure=EngineFailure(reason:"音频工具退出状态无法确认，未保存为成功结果。",solution:"请检查音频工具后重试。",code:"audio_invalid")}
                }
            }
            if reaped,eof {break}
            // If a detached daemon inherited the pipe, closing our read end
            // must not turn cancellation into an unbounded pipe drain.
            if killed,reaped {break}
            if eof {usleep(10_000)}
            else {var poller=pollfd(fd:input,events:Int16(POLLIN|POLLHUP),revents:0);_=poll(&poller,1,10)}
        }
        if let failure=failure {kill(-pid,SIGKILL);throw failure}
        if isCancelled {kill(-pid,SIGKILL);throw CancellationError()}
        if Self.groupMayRemain(pid) {
            kill(-pid,SIGKILL)
            throw EngineFailure(reason:"音频工具仍有未结束的后台任务，已停止处理。",solution:"请检查音频工具版本后重试。",code:"audio_invalid")
        }
        guard status & 0x7f==0,(status>>8)&0xff==0 else {
            let text=(String(data:bytes,encoding:.utf8) ?? "").lowercased()
            if ["no space left on device","permission denied","read-only file system","disk quota exceeded"].contains(where:{text.contains($0)}) {
                throw EngineFailure(reason:"音频工具无法写入文件。",solution:"请检查磁盘空间、配额和目录权限，或更换保存位置。",code:"filesystem")
            }
            throw EngineFailure(reason:"音频校验或转换未完成。",solution:"请检查FFmpeg/FFprobe，或换其他音源版本。",code:"audio_invalid")
        }
        return bytes
    }
}
