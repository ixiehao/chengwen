# 澄闻

**macOS 音乐下载与收藏**

**0.9.5** · [Apple 芯片（arm64）](https://github.com/ixiehao/chengwen/releases/download/v0.9.5-preview.1/chengwen-0.9.5-arm64.dmg) · [Intel（x86_64）](https://github.com/ixiehao/chengwen/releases/download/v0.9.5-preview.1/chengwen-0.9.5-x86_64.dmg)

![搜索界面（合成数据）](docs/screenshot.png)

## 功能

- 按歌名、歌手或专辑搜索，可同时勾选网易云音乐、酷我音乐、酷狗音乐、QQ 音乐、咪咕音乐和千千音乐。
- 单首或批量下载，可选原始格式、MP3、M4A、FLAC 或 WAV。音源提供歌词时可同时保存 LRC 文件。
- 搜索后可直接下载，也可先做「预下载测试」试读音频。保存前校验整首音频，同名文件自动编号。
- 在「下载管理」查看进度和历史记录，重试失败任务或换源搜索。
- 默认免登录。可在「偏好设置」连接网易云音乐或酷我音乐账号。可下载的歌曲以平台提供的权限为准。

## 安装

1. 最低系统要求为 macOS 12。在  菜单打开「关于本机」，按芯片或处理器选择对应的安装包。[Apple 的机型识别说明](https://support.apple.com/zh-cn/116943)
2. 打开 DMG，将「澄闻」拖入「应用程序」。安装包采用临时签名，尚未经过 Apple 公证。首次打开时如提示无法验证开发者，请先核对 SHA-256，再参考系统说明。[安装包与 SHA-256 校验文件](https://github.com/ixiehao/chengwen/releases/latest) · [Apple 的打开应用说明](https://support.apple.com/zh-cn/102445)
3. 下载和转换音频需要 FFmpeg 与同目录的 FFprobe。打开澄闻，在右上角点击「运行环境测试」查看安装方法和工具状态。[音频工具安装](docs/AUDIO_TOOLS.md)

澄闻采用 MIT 许可证。[从源码运行](docs/DEVELOPMENT.md) · [许可证](LICENSE) · [第三方声明](THIRD_PARTY/README.md) · [隐私](PRIVACY.md) · [安全报告](SECURITY.md) · [项目文档](docs/README.md)
