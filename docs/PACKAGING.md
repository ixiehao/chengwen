# 双架构 DMG 打包

先按[开发文档](DEVELOPMENT.md)完成验证。需要 macOS、Swift 工具链、Python 3.9+、uv、FFmpeg/同目录 FFprobe，以及可执行目标架构的环境。首次运行会在构建机创建隔离 Python 3.12.13，并安装固定的 dmgbuild/ds-store/mac-alias；不会装进 App。

```sh
python3 macos/package_dmg.py --preflight --output-dir dist/native/new-preview
python3 macos/package_dmg.py --output-dir dist/native/new-preview
```

默认顺序生成 arm64 和 x86_64 两包，可用 `--architecture arm64|x86_64` 单独构建。已有目标、报告、校验和或悬空链接均拒绝覆盖。`--preflight` 仅检查源码、工具与目标冲突；`--skip-build` 仅供明确复用已验证编译产物的维护场景，实际版本与资源不一致仍会失败。

## 版本、源码与签名

`澄闻.app/Contents/Info.plist` 和 `Sources/ChengWen/Resources/Version.json` 必须有相同 version/build；打包前和安装副本验证时都检查。每次公开交付递增版本或 build，记录 CHANGELOG，不覆盖旧版。Release.json 和验证报告记录源码 SHA-256、真实工具链及主机环境；Git 提交与 dirty 只在本项目实际 Git 仓库中读取，未建仓时明确为 null。

Swift Release 使用 `-Osize`。先核对 EXE/dSYM 的 UUID/CPU 并归档匹配符号，再只对发行副本 `strip -S -x` 并重签。App 包含单一主 Mach-O、Tabler 资源、图标、项目自身 MIT LICENSE、三项第三方 MIT 声明、Release.json 和可重建的公开源码 ZIP。许可证缺失、版本冲突、源码变化或旧运行时混入均阻止交付。构建可重建不代表 ZIP/DMG 的时间戳或签名字节完全相同。

0.9.0品牌更名后使用ChengWen-source-v3摘要域；文件模式与长度规则沿用v2。0.8.2的源码摘要使用v2输入格式，包含归一化的文件执行权限和内容长度，不能与旧版摘要直接比较。独立源码导出先在目标卷暂存ZIP、校验和与含文件权限的清单，再排他发布；不能导出到`Sources/`或`Tests/`等输入位置，失败不留下本次半套产物，也不覆盖其他调用的文件。

当前输出为 ad-hoc 签名、未公证的本地预览包。Apple 验证的发布者身份和正式公证需另行配置 Developer ID/notary 凭据，凭据不得进入源码。公证不是源码开源的前提；当前脚本不会假称已公证，不修改用户系统安全设置。

## 并发、失败与输出

进程所有权锁保护共享 SwiftPM 缓存、宿主工具环境和符号归档；第二次并发调用立即失败。锁文件保留其 inode，存在不代表被占用；正常退出和 SIGINT/SIGTERM 会释放 flock 并终止本次子进程组。不要凭锁文件存在删除它。

取消先向自有进程组发TERM；直接子进程退出后仍检查后代，最多等待5秒后对残留组发KILL。验证及源码导出入口也处理SIGINT/SIGTERM。主动脱离此进程组的外部守护进程、强制杀死父脚本或断电不在该清理保证内。

暂存目录由本次调用创建。挂载验证只卸载本次拥有的挂载点，包含“attach 实际挂载后却返回失败”的清理路径。卸载失败时保留暂存目录，并在 `.build-release/packaging-blocked.json` 记录位置，阻止下一轮打包。应先核对该记录、手动安全弹出对应安装卷，确认已卸载后再清理记录及暂存目录；不要删除仍挂载的镜像。强制杀进程或断电不保证执行清理，重试前先检查安装卷。

产物用本地文件系统支持的排他重命名发布，不要求硬链接，且不会覆盖已有文件；若目标卷不支持排他重命名（部分 ExFAT），会明确失败，请改用本地 APFS 输出再复制完整产物组。该限制只针对构建产物目录，不改变 App 保存音频到其他卷的策略。发布中途失败会回滚本次已移动的文件，保留不属于本次调用的旧文件。

## 安装器验证

DMG 使用 ULMO 压缩，应用最低 macOS 12。安装界面保持统一 960×600 浅蓝背景、128px 图标、应用(260,298)、Applications(700,298)、箭头与双语说明。每个 CPU 核对实际 Mach-O 和 Launch Services 系统下限、签名、许可证、源码、DMG 校验和及 Finder 布局，再复制到隔离目录运行原生 UI、WebKit 合成连接和五格式本地媒体回归。

产物附 `.dmg.sha256` 与 `-verification.json`。本机/Rosetta 成功不替代 macOS 12 或物理 Intel 验收；没有上传、创建 Release 或覆盖用户安装的步骤。
