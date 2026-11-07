# Kindle 书库

源 ID：`kindle`，整本书模式。仅在 Kindle 设备上提供，书架数据直接读取 Kindle 系统数据库 `/var/local/cc.db`。

## 书籍范围

列出 Kindle 首页可见、未归档且有本地路径的 KFX，以及带 DRM 标记的 MOBI／AZW／AZW3。无 DRM 的常规书籍由本地书源扫描，不重复列入 Kindle 源。

书架同步是只读查询系统数据库；封面使用 Kindle 已有缩略图。同步不访问网络，也不写入 Kindle 系统数据库。

## 打开 Kindle 书

打开 DRM/KFX 书依赖单独安装的 `kindle.koplugin`。月读把选中的系统书籍路径交给该插件处理，并使用其返回的可读路径；月读本身不实现 DRM 解密。KFX 首次转换可能耗时较长；大文件会提示转换的内存风险。转换后的缓存 EPUB 可被复用。

可在该书源设置页检查、安装或更新 `kindle.koplugin`。安装后需重启 KOReader。

## 限制

- Kindle 系统数据库和 `kindle.koplugin` 不可用时，源无法提供书籍或打开功能。
- 本源不上传进度、笔记或统计，也不修改 Kindle 系统书架。
- 月读对系统数据库只读；编辑的展示元信息仅保存在月读本地，不会改写 Kindle 原始数据。

实现位于 `init.lua`；依赖插件安装与更新逻辑位于 `plugin_update.lua`。
