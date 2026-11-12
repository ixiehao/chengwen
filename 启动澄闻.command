#!/bin/zsh
set -e
cd -- "${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if (( ${$(/usr/bin/sw_vers -productVersion)%%.*} < 12 )); then
    echo "澄闻需要 macOS 12 Monterey 或更高版本。"
    read -r "?按回车关闭…"
    exit 1
fi
if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    echo "源码构建需要 Xcode Command Line Tools；安装 DMG 版无需开发工具。"
    read -r "?按回车关闭…"
    exit 1
fi
echo "正在构建 Swift 原生应用…"
swift build --scratch-path .build-native -c debug
if [[ "${1:-}" == "--prepare-only" ]]; then
    echo "澄闻原生应用已就绪。"
    exit 0
fi
binary_dir="$(swift build --scratch-path .build-native -c debug --show-bin-path)"
[[ -n "$binary_dir" && -x "$binary_dir/ChengWen" ]] || { echo "未找到构建后的澄闻。"; exit 1; }
exec "$binary_dir/ChengWen" "$@"
