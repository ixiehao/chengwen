# 第三方组件

澄闻 0.9.5 使用 Swift、SwiftUI、AppKit 和 WebKit，调用 macOS 系统网络及加密框架。应用不携带 Python、You-Get、spotDL、yt-dlp、Qt 或 PyObjC。

| 资源 / 参考 | 来源与许可 |
| --- | --- |
| Tabler Icons v3.35.0 | [官方项目](https://github.com/tabler/tabler-icons)，[MIT原文](tabler-icons-LICENSE.txt)。按固定版本官方 Outline SVG 导出，界面使用静态 PNG；资源及声明纳入发行源码摘要。 |
| TuneWeave 请求编码 | [固定提交](https://github.com/MOPELotus/TuneWeave/tree/b6e35c0999965d56ba61b2cfc146218b5763b343)提供 MIT 或 Apache-2.0 双许可，本项目选用 [MIT](TuneWeave-MIT.txt)。仅移植酷我请求编码和公开测试向量，不含音频解密。 |
| Listen1公开协议参考 | [固定commit](https://github.com/listen1/listen1_chrome_extension/tree/3f24efa045125875a609dcb0f3f3f0be4edb8b37)，[MIT原文](Listen1-MIT.txt)。参考四个新增来源的公开检索、请求参数和响应模型，以Swift实现并根据0.7.0引擎验证时的官方响应修正；不携带扩展、浏览器会话逻辑或JS运行时。 |

[dependencies.json](dependencies.json)记录实际分发的三项资源/参考。对应许可证随App和可构建源码一起提供。FFmpeg与FFprobe由用户安装，依其构建选项适用LGPL/GPL等许可，未复制入App。Python、dmgbuild只用于构建机，不是应用运行依赖。旧Python引擎及许可材料作为历史版本另存，不混入当前安装包。

澄闻 自有源码采用根目录的 MIT LICENSE；第三方材料保留各自声明。安装包保留必要声明和可构建原生源码；源码中的修改说明不将上游材料重新许可。软件许可、平台使用条款和音乐内容权利分别适用。

## 品牌与图标再生成

澄闻的「双韵」品牌图形由两个相连的八分音符组成，由 [`BrandLogo.swift`](../Sources/ChengWen/BrandLogo.swift) 绘制，适用项目根 MIT 许可证。可先在临时目录导出 PNG：

```sh
swiftc -parse-as-library Sources/ChengWen/BrandLogo.swift tools/build-brand-icon.swift -o /tmp/chengwen-brand-builder
/tmp/chengwen-brand-builder /tmp/chengwen-brand-png
```

Tabler 资源使用上表固定的 v3.35.0，不使用未标明许可的音乐平台商标图片。若需重新导出，从该版本官方 `icons/outline/` 选取现有 PNG 同名的 SVG，并将官方 LICENSE 放入同一个输入目录，再运行：

```sh
swift tools/export-tabler.swift /path/to/selected-svg-and-license /tmp/chengwen-tabler-png
```

先检查临时输出和许可证，再替换资源；原始 PNG 本身已随源码提供，普通构建无需重新下载图标。
