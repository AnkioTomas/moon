---@meta

--- 数据源身份 id。
--- 与 `source.registry` 注册键、`settings.active_source` 一致。
--- 内置：moon（Book 服务）/ webdav / wechat（微信读书）；亦可扩展自定义字符串。
---@alias SourceId "moon"|"webdav"|"wechat"|string

--- 数据源展示元信息（设置页切换源、顶栏当前源名）。
--- 由各源模块 `meta()` 返回；不构造 Source 实例即可读取。
---@class BookSourceMeta
---@field id SourceId 源身份，唯一
---@field name string 本地化展示名
