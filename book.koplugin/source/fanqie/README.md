# 番茄小说数据源

在月读设置中启用并切换至“番茄小说”，通过账号设置扫码登录后刷新书架。
可复用 KOReader 原番茄插件的 `settings/fanqie.lua` 登录及 `fanqie/cache` 缓存；不需要运行旧插件。
目录、正文、预取、阅读位置和全书排版由月读的章节阅读框架管理。

## 正文

正文走番茄 App reading 协议（本地签发四神头）：

1. `POST /reading/crypt/registerkey` → 会话密钥 `v1_key`
2. `GET /reading/reader/batch_full/v` → 密文章节
3. AES-CBC(`v1_key`) + 可选 gzip → 明文 HTML

实现在 `source/fanqie/reading/`，算法对齐 fanqie-re（Khronos / Ladon / Helios / Argus）。
设备身份：**每台安装各自**向 `log.snssdk.com/service/2/device_register/` 注册，
拿到专属 `device_id`/`install_id` 后写入源配置 `reading_device`；禁止复用别人的 did。
首次拉正文会自动注册；`log.snssdk.com` 被广告拦截时会失败，需放行该域名。

书架 / 目录 / 进度仍走官网网页接口；扫码登录拿 `sessionid`。

协议、扫码登录、目录解析和字体编码转换改编自
[hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin)
的官方网页适配版本，模块隔离在 `source.fanqie` 中。
发布代码不包含 Cookie、个人书架、正文、字体文件或设备日志。

图片组件现在缓存已缩放的像素数据：4 MiB 内存、约 24 MiB / 128 项磁盘缓存。
首次显示仍需下载或解码；重复访问及重启后可直接使用缩略图。
文件大小、修改时间或显示尺寸改变会失效重建，损坏缓存自动回退后台解码。
