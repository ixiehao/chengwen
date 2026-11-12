# 安全策略

## 当前状态

当前支持 **0.9.5**。报告时请注明安装包的构建编号或源码提交。

## 私密报告

请登录 GitHub，通过[私密漏洞报告表单](https://github.com/ixiehao/chengwen/security/advisories/new)提交。也可以进入仓库的 **Security → Advisories → Report a vulnerability**。普通功能问题和界面反馈请使用 [Issues](https://github.com/ixiehao/chengwen/issues)。

请提供受影响的版本或提交、macOS 版本、影响和最小复现。样本请使用合成数据，并移除账号、Cookie、SID、登录二维码、签名媒体地址、私有路径和私人音频。请勿把漏洞细节贴到公开 Issue 或 Pull Request；维护者会在私密报告中沟通确认、修复和披露。

## 边界

- 默认匿名，账号仅在明确启用后用于相应平台；会话保存在钥匙串，不向音频 CDN 传递 Cookie/SID。
- 平台限流、权限拒绝、试听和安全挑战不是需要绕过的错误；不通过第三方解析站补链。
- FFmpeg/FFprobe 是外部可执行文件，软件按固定位置及 PATH 查找，通过参数调用而非拼接 shell。它们自身的来源、更新及安全性由安装者负责。
- App 未启用沙盒，拥有当前用户授予的本地文件访问能力。私有暂存、完整性校验和不覆盖已有文件用于保护正常操作，但不能替代对未知媒体及外部工具的审慎选择。
- 当前安装包采用临时签名，尚未经过 Apple 公证。签名与公证流程见 [打包文档](docs/PACKAGING.md)。
