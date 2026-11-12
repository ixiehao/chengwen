# 第三方组件

| 资源 / 参考 | 来源与许可 |
| --- | --- |
| Tabler Icons v3.35.0 | [官方项目](https://github.com/tabler/tabler-icons)，[MIT原文](tabler-icons-LICENSE.txt)。按固定版本官方 Outline SVG 导出，界面使用静态 PNG；资源及声明纳入发行源码摘要。 |
| TuneWeave 请求编码 | [固定提交](https://github.com/MOPELotus/TuneWeave/tree/b6e35c0999965d56ba61b2cfc146218b5763b343)提供 MIT 或 Apache-2.0 双许可，本项目选用 [MIT](TuneWeave-MIT.txt)。用于酷我音乐请求编码及其测试向量。 |
| Listen1 音源协议参考 | [固定提交](https://github.com/listen1/listen1_chrome_extension/tree/3f24efa045125875a609dcb0f3f3f0be4edb8b37)，[MIT 原文](Listen1-MIT.txt)。用于酷狗音乐、QQ 音乐、咪咕音乐和千千音乐的检索、请求参数和响应模型参考。 |

[dependencies.json](dependencies.json) 记录上述资源及其版本。对应许可证随源码和应用分发。FFmpeg 和 FFprobe 由用户另行安装，许可取决于所用的构建版本。

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
