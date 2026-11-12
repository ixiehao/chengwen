# macOS Monterey 12.7.6

0.9.5 的最低部署目标为 macOS 12.0。Apple 芯片对应 arm64，Intel 对应 x86_64。

每个安装包检查全部Mach-O的实际架构、系统门槛、签名和复制后启动；DMG的ULMO压缩由macOS10.15开始支持，低于本应用的系统门槛。开发机/Rosetta验证不替代Monterey12.7.6或物理Intel实机验收。

运行环境测试实际执行 FFmpeg 与同目录的 FFprobe。可用 [MacPorts](https://www.macports.org/install.php) 安装，或从 [FFmpeg 官网列出的构建](https://ffmpeg.org/download.html)取得支持 macOS 12 和本机芯片的同一套工具，放入运行环境测试打开的工具文件夹。

源码构建需要 Swift 工具链。通过 MacPorts 安装音频工具时，请按 MacPorts 的安装说明准备对应的开发工具。

运行环境测试内可直接切换「MacPorts / Monterey」，复制安装命令并打开官方说明；也可手动放入两项兼容工具。完整步骤见[音频工具安装](AUDIO_TOOLS.md)。
