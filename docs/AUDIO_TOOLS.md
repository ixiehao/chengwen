# 音频工具安装

音乐引擎已经内置，不需要安装 Python 或第三方下载框架。外部依赖只有 **FFmpeg 和同目录的 FFprobe**：前者负责格式转换与完整解码校验，后者读取音频信息。选择「原始格式」也会做完整校验，因此仍需两个工具。环境测试显示均已就绪时，无需重复安装。

右上角「运行环境测试」和偏好设置的运行环境页始终提供安装步骤，不要求先出现缺失错误。

## 已有 Homebrew

打开 macOS「终端」，运行：

```sh
brew install ffmpeg
```

该公式同时提供 ffmpeg 和 ffprobe。[公式与二进制清单](https://formulae.brew.sh/formula/ffmpeg)、[Homebrew 安装说明](https://brew.sh/)。

截至2026-11-03，Monterey 等较旧系统及 Intel 不在 Homebrew 完整支持范围内，可能缺少预编译包；建议选择下方 MacPorts 或明确兼容系统的手动构建。[Homebrew 支持范围](https://docs.brew.sh/Support-Tiers)。

## MacPorts / Monterey

1. 打开 [MacPorts 官方安装说明](https://www.macports.org/install.php)，选择与你的系统版本匹配的安装器，Monterey 请选择 macOS 12。按官网要求安装对应的开发工具。
2. 安装 MacPorts 后，在「终端」运行下面的命令；终端可能要求输入本机管理员密码。

```sh
sudo port install ffmpeg
```

[MacPorts 的 FFmpeg 安装说明](https://ports.macports.org/port/ffmpeg/)。编译和安装所需时间取决于系统、可用二进制包与本机环境；本项目没有在 Monterey 实机执行此安装。

## 手动安装

1. 从 [FFmpeg 官网的 macOS 下载入口](https://ffmpeg.org/download.html)选择构建。预编译程序由官网列出的第三方提供，分别下载 ffmpeg 和 ffprobe，核对 CPU（Apple 芯片 / Intel）和最低 macOS 版本；Monterey 需明确支持 macOS 12。
2. 解压两个程序，在环境测试中点击「打开工具文件夹…」，将 **ffmpeg、ffprobe 可执行文件本身**放到 `~/Library/Application Support/澄闻/bin/`。不要只放压缩包或外层文件夹；不要把不同发行版、不同 CPU 的工具混用。
3. 按 macOS 提示核实来源与兼容性。无法运行时，可改用上面的包管理器安装；App 不修改系统安全设置，也不自动执行安装命令。

## 验证

回到环境测试，点击「重新检查」。FFmpeg 与 FFprobe 均应显示已就绪、版本与真实路径。应用优先查找专用工具文件夹，其次 Homebrew、MacPorts 和 PATH；FFprobe 必须与选中的 FFmpeg 位于同一目录。

若安装了新工具但仍指向旧工具，请检查上述优先级，特别是专用工具文件夹内是否有旧版本。只有工具实际成功运行才显示就绪；不兼容芯片、系统版本或执行权限问题会显示失败。
