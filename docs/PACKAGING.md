# 双架构 DMG 打包

构建机需要 macOS、Swift 工具链、Python 3.9+、uv、FFmpeg 与同目录的 FFprobe，并能运行目标架构。首次打包会创建隔离的 Python 3.12.13 工具环境。按[开发文档](DEVELOPMENT.md)准备环境后，从项目根目录运行以下命令。每次打包使用独立的输出目录。

```sh
python3 scripts/validate.py
python3 macos/package_dmg.py --preflight --output-dir dist/native/0.9.5-build907
python3 macos/package_dmg.py --output-dir dist/native/0.9.5-build907
(cd dist/native/0.9.5-build907 && shasum -a 256 -c ./*.dmg.sha256)
```

默认生成 Apple 芯片（`arm64`）和 Intel（`x86_64`）两包。可用 `--architecture arm64` 或 `--architecture x86_64` 单独构建。DMG 文件名为 `chengwen-<版本>-<架构>.dmg`，本地与 GitHub Release 使用相同的文件名。已有目标、校验文件、验证报告或悬空链接均拒绝覆盖。`--preflight` 检查源码、工具和产物冲突。`--skip-build` 只复用本脚本记录且源码、工具链、可执行文件与资源均匹配的构建。

## 版本、源码与签名

`澄闻.app/Contents/Info.plist` 和 `Sources/ChengWen/Resources/Version.json` 必须有相同 version/build；打包前和安装副本验证时都检查。每次公开交付递增版本或 build，记录 CHANGELOG，不覆盖旧版。Release.json 和验证报告记录源码 SHA-256、真实工具链及主机环境；Git 提交与 dirty 只在本项目实际 Git 仓库中读取，未建仓时明确为 null。

Swift Release 使用 `-Osize`。先核对 EXE/dSYM 的 UUID/CPU 并归档匹配符号，再只对发行副本 `strip -S -x` 并重签。App 包含单一主 Mach-O、Tabler 资源、图标、项目自身 MIT LICENSE、三项第三方 MIT 声明、Release.json 和可重建的公开源码 ZIP。许可证缺失、版本冲突、源码变化或旧运行时混入均阻止交付。构建可重建不代表 ZIP/DMG 的时间戳或签名字节完全相同。

0.9.0品牌更名后使用ChengWen-source-v3摘要域；文件模式与长度规则沿用v2。0.8.2的源码摘要使用v2输入格式，包含归一化的文件执行权限和内容长度，不能与旧版摘要直接比较。独立源码导出先在目标卷暂存ZIP、校验和与含文件权限的清单，再排他发布；不能导出到`Sources/`或`Tests/`等输入位置，失败不留下本次半套产物，也不覆盖其他调用的文件。

当前脚本生成采用 ad-hoc 签名且未公证的 DMG。配置 Developer ID 签名和 Apple 公证时，凭据应保存在钥匙串或 CI Secrets。公证后应验证票据、Gatekeeper，并在 Monterey 和目标芯片上做实机验收。

## 并发、失败与输出

进程所有权锁保护共享 SwiftPM 缓存、宿主工具环境和符号归档；第二次并发调用立即失败。锁文件保留其 inode，存在不代表被占用；正常退出和 SIGINT/SIGTERM 会释放 flock 并终止本次子进程组。不要凭锁文件存在删除它。

取消先向自有进程组发TERM；直接子进程退出后仍检查后代，最多等待5秒后对残留组发KILL。验证及源码导出入口也处理SIGINT/SIGTERM。主动脱离此进程组的外部守护进程、强制杀死父脚本或断电不在该清理保证内。

暂存目录由本次调用创建。挂载验证只卸载本次拥有的挂载点，包含“attach 实际挂载后却返回失败”的清理路径。卸载失败时保留暂存目录，并在 `.build-release/packaging-blocked.json` 记录位置，阻止下一轮打包。应先核对该记录、手动安全弹出对应安装卷，确认已卸载后再清理记录及暂存目录；不要删除仍挂载的镜像。强制杀进程或断电不保证执行清理，重试前先检查安装卷。

产物用本地文件系统支持的排他重命名发布，不要求硬链接，且不会覆盖已有文件；若目标卷不支持排他重命名（部分 ExFAT），会明确失败，请改用本地 APFS 输出再复制完整产物组。该限制只针对构建产物目录，不改变 App 保存音频到其他卷的策略。发布中途失败会回滚本次已移动的文件，保留不属于本次调用的旧文件。

## 安装器验证

DMG 使用 ULMO 压缩，应用最低 macOS 12。安装界面保持统一 960×600 浅蓝背景、128px 图标、应用(260,298)、Applications(700,298)、箭头与双语说明。每个 CPU 核对实际 Mach-O 和 Launch Services 系统下限、签名、许可证、源码、DMG 校验和及 Finder 布局，再复制到隔离目录运行原生 UI、WebKit 合成连接和五格式本地媒体回归。

产物附 `.dmg.sha256` 与 `-verification.json`。本机/Rosetta 成功不替代 macOS 12 或物理 Intel 验收；没有上传、创建 Release 或覆盖用户安装的步骤。

## 发布核对

从干净提交打包，核对两个验证报告中的源码提交和摘要，再用该提交创建版本标签。Release 附两个 DMG 和各自的 SHA-256 校验文件，附件显示完整文件名，安装包另标明芯片。发布后通过公开下载链接重新取回文件并校验 SHA-256，再确认 README 的下载入口和版本号。
