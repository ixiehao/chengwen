# 开发与验证

本项目为 macOS 12+ 的 Swift Package，界面使用 SwiftUI/AppKit，运行时不需要 Python、Node 或第三方音乐下载引擎。`Package.swift` 的工具版本要求为 Swift 5.7；采用支持该工具版本的 Xcode/Command Line Tools。实际发布应记录所用 Swift/Xcode 版本，最低部署版本不等于构建机系统版本。

## 准备开发机

- 安装 Xcode Command Line Tools，并确认 `xcrun --find swift` 与 `swift --version` 可运行。
- 源码启动：`./启动澄闻.command`。脚本通过 `swift build --show-bin-path` 找到当前工具链的实际输出，不依赖特定 Xcode 构建目录。
- 完整媒体测试和 DMG 的安装副本检查需要同一安装目录中的 FFmpeg/FFprobe，见[音频工具安装](AUDIO_TOOLS.md)。例如通过已安装的 Homebrew 执行 `brew install ffmpeg`，并将其 bin 目录加入 PATH。
- 宿主脚本要求 Python 3.9+。安装 [uv](https://docs.astral.sh/uv/getting-started/installation/)；验证脚本用隔离 Python 3.12.13 和 `dev-requirements.txt` 中的 pytest，打包工具版本另见 `macos/build-requirements.txt`。首次准备需要网络；这些工具不会进入 App。
- 双架构安装副本执行检查需要可运行目标 CPU 的主机；Apple Silicon 测试 Intel 包时需要已安装 Rosetta。交叉编译、Rosetta 与物理 Intel 验收分别记录。

## 一次完整验证

从项目根目录执行：

```sh
python3 scripts/validate.py --preflight
python3 scripts/validate.py
```

预检不构建、不安装依赖、不访问音乐账号。完整命令按顺序检查自身及第三方许可证、公开文件白名单与版本一致性，执行宿主故障测试和 Swift 测试，编译 arm64/x86_64 Release，并将公开源码包提取到随机临时路径、用独立构建缓存重新编译。`--skip-native-builds` 仅用于明确跳过两个 Release 编译的快速验证；不等于完整发行门禁。

单独排查时：

```sh
swift test --scratch-path .build-native-validation
PYTHONDONTWRITEBYTECODE=1 uv run --isolated --no-project --python 3.12.13 \
  --with-requirements dev-requirements.txt python -m pytest -q -p no:cacheprovider Tests/test_packaging.py
python3 scripts/verify_public_source.py
```

原生窗口测试使用合成数据和隔离存储，部分用例需要 macOS 窗口服务；不用真实会员账号、浏览器会话或私有音乐验证。测试失败保留失败证据并修复，不删除断言来获得通过。真实平台可用性、会员授权与 macOS 12/物理 Intel 需要另做获授权的人工验证。

## 公开源码与协作

`Sources/`、`Tests/` 的大小写是接口的一部分；测试目标在 manifest 中明确指定 `Tests/ChengWenTests`。不复制整个工作目录公开：

```sh
python3 scripts/export_source.py /path/to/new/澄闻-source.zip
```

脚本只导出审查后的白名单，包含 MIT LICENSE、隐私/安全/贡献说明、CI、测试、构建脚本和必要资源，附 ZIP 校验和及含执行权限的逐文件清单；先暂存完整三件套再排他发布，目标已存在时拒绝覆盖，失败回滚本次输出。不要导出到 `Sources/` 或 `Tests/`。历史引擎、私有维护记录、缓存与个人材料不进入导出。无 Git 仓库时构建信息的提交/dirty 值为 null，不虚构提交。

GitHub CI 仅执行验证，不部署、不发布。它使用固定官方 Action commit，安装隔离宿主依赖和 FFmpeg，失败时归档验证日志。新增 CI 配置不代表远端已运行通过。变更记录见 [CHANGELOG](../CHANGELOG.md)，贡献及敏感信息反馈分别见 [CONTRIBUTING](../CONTRIBUTING.md)、[SECURITY](../SECURITY.md)。
