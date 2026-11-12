# 澄闻 · 品牌

- 名称：**澄闻**；副标题：**音乐下载与收藏**。
- 标语：**把喜欢的声音，留给自己。**
- 原创标志采用已确认的 09「双韵」：两个白色实心符头、两根略弯符干及一条柔和连接横梁，组成两个相连的八分音符。严格保留定稿的 1024 画布坐标和比例。
- 正式矢量源：`Assets/Brand/ChengWen.svg`；AppKit 等价绘制：`Sources/ChengWen/BrandLogo.swift`。
- 紫色渐变从 `#4A29C2` 到 `#9877FF`，音符为白色 `#FFFFFF`；不随包分发字体，不复制平台商标作为本产品标志。

从项目根目录导出：

```sh
swiftc -parse-as-library Sources/ChengWen/BrandLogo.swift tools/build-brand-icon.swift -o /tmp/chengwen-brand-icon
/tmp/chengwen-brand-icon /tmp/chengwen-brand-png
```

PNG 尺寸为16、32、64、128、256、512、1024；由同一绘制生成侧栏、Dock 与 ICNS，避免不同标志混用。安装包沿用统一的浅蓝色安装器版式。

## 升级兼容

Swift 模块和主程序为 `ChengWen`，产品、项目目录、App 和安装包为「澄闻」。现有系统 Bundle ID 与钥匙串 service 是不可随品牌名称更改的兼容标识；修改它们会改变系统身份及账号授权关系。

升级时若原数据目录 `~/Library/Application Support/VmDown` 已存在，仍使用原位置，不复制账号元数据、不读取钥匙串来执行迁移，也不移动用户歌曲。会话键与该目录路径绑定。新安装使用 `~/Library/Application Support/澄闻`，新下载默认保存至 `~/Music/澄闻`；用户自选目录和既有历史路径照常保留。

这些兼容标识不作为界面或安装包品牌。正式商标与近似名称核查仍需在公开发布前完成，本次名称及原创图形落地不代表商标已注册。
