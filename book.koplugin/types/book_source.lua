--- Source 接口与能力表。可 require：仅 SourceCapabilities.defaults 为运行时。

---@alias SourceId "moon"|"webdav"|"wechat"|"rss"|"local"|string

---@alias BookSourceType
---| '"book"' # 整本文件
---| '"online"' # 在线书籍，按章阅读
---| '"article"' # 文章订阅，按章阅读

---@class BookSourceMeta
---@field id SourceId
---@field name string
---@field type BookSourceType 阅读形态
---@field preview boolean|nil 实验源；未完成前不进正式列表

--- 能力是用户可用功能，不是「模块里有没有函数」。
--- 仅保留可选 UI 功能；Source 基础契约和阅读形态不放在能力表中。
---@class SourceCapabilities
---@field library boolean 图书馆列表（listLibrary）
---@field search boolean 图书馆关键词搜索（BookListOpts.search）
---@field refresh boolean 支持手动强制重扫书库（本地源；opts.force）
---@field detail boolean 书籍详情（getDetail）
---@field scrape boolean 支持把外部元数据写入本地书籍记录
---@field insight boolean 阅读洞察 / 统计页（readingInsight）
---@field store boolean 源自带书城（listStore；无则走全局 zlib）

local SourceCapabilities = {}

--- 返回全 false 的默认能力表。
---@return SourceCapabilities
function SourceCapabilities.defaults()
    return {
        library = false,
        search = false,
        refresh = false,
        detail = false,
        scrape = false,
        insight = false,
        store = false,
    }
end

--- 图书馆筛选项；只支持分类和系列。
---@class BookFiltersResult
---@field data { category: string[]|nil, series: string[]|nil }|nil

--- 统计上报中的书籍身份（源内 stable_id）。
---@class BookStatsBook
---@field stable_id string 源内稳定身份；moon 即为 filename

--- 单条阅读会话统计（落盘 reading_stats 后上报）。
---@class BookStatsRow
---@field stable_id string 源内书籍身份
---@field page number 结束页
---@field start_time number 会话开始时间戳（秒）
---@field duration number 阅读时长（秒）
---@field total_pages number 全书页数
---@field device_id string|nil 采集设备 ID

--- importReadingStats 载荷。
---@class BookStatsPayload
---@field books BookStatsBook[]|nil 涉及的书籍身份去重列表
---@field stats BookStatsRow[]|nil 会话明细
---@field device_id string|nil 上报设备 ID

--- 封面 HTTP 请求描述（UI 线程同步取，再异步下载）。
---@class BookCoverRequest
---@field url string 封面 URL 或本地 file:// 路径
---@field headers table 附加请求头（可空表）

--- 源配置状态：决定设置页提示与是否可发起请求。
---@alias SourceConfigurationState
---| '"ready"' # 已配置且可用
---| '"needs_login"' # 需登录（如 wechat）
---| '"needs_config"' # 需填写配置（路径 / 服务器等）
---| '"unavailable"' # 当前不可用

--- 按章正文载荷：Source 只交内容，宿主写 HTML。
---@class ChapterContentPayload
---@field title string|nil 章节标题
---@field html string|nil HTML/XHTML 正文片段（优先）
---@field text string|nil 纯文本（无 html 时由宿主转段落）

--- 统一数据源实例接口。
--- 同步方法失败一律 (data|nil, string|nil)；Async 经 cb(data, err)，返回值可为可取消 job 或 nil。
---@class BookSource
---@field id SourceId|nil 源标识
---@field name string|nil 展示名
---@field type BookSourceType 阅读形态
---@field onEvent fun(self: BookSource, event: string, payload: table|nil)|nil 生命周期事件（见 source.base 注释）
---@field capabilities fun(self: BookSource): SourceCapabilities 能力表
---@field configurationState fun(self: BookSource): SourceConfigurationState 配置状态
---@field configured fun(self: BookSource): boolean 是否已配置到可请求
---@field ping fun(self: BookSource): (table|nil, string|nil) 连通探测
---@field pingAsync fun(self: BookSource, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 图书馆列表
---@field listLibraryAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 书城列表
---@field listStoreAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil) 最近阅读
---@field recentBooksAsync fun(self: BookSource, limit: number|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil) 筛选项
---@field filtersAsync fun(self: BookSource, cb: fun(data: BookFiltersResult|nil, err: string|nil)): table|nil
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil) 阅读洞察
---@field readingInsightAsync fun(self: BookSource, cb: fun(data: BookInsightResult|nil, err: string|nil)): table|nil
---@field clearCaches fun(self: BookSource) 清空源侧缓存
---@field close fun(self: BookSource)|nil 释放资源
---@field getDetail fun(self: BookSource, ref: BookRef): (BookDetail|nil, string|nil) 书籍详情
---@field getDetailAsync fun(self: BookSource, ref: BookRef, cb: fun(data: BookDetail|nil, err: string|nil)): table|nil
---@field getProgress fun(self: BookSource, ref: BookRef): (ProgressPosition|nil, string|nil) 拉取远端进度
---@field getProgressAsync fun(self: BookSource, ref: BookRef, cb: fun(data: ProgressPosition|nil, err: string|nil)): table|nil
---@field putProgress fun(self: BookSource, ref: BookRef, pos: ProgressPosition): (boolean|nil, string|nil) 推送进度
---@field putProgressAsync fun(self: BookSource, ref: BookRef, pos: ProgressPosition, cb: fun(ok: boolean|nil, err: string|nil)): table|nil
---@field getToc fun(self: BookSource, ref: BookRef): (BookChapter[]|nil, string|nil) 目录
---@field getTocAsync fun(self: BookSource, ref: BookRef, cb: fun(data: BookChapter[]|nil, err: string|nil)): table|nil
---@field fetchChapterContentAsync fun(self: BookSource, ref: BookRef, chapter: BookChapter, cb: fun(payload: ChapterContentPayload|nil, err: string|nil)): table|nil 按章正文
---@field materializeWhole fun(self: BookSource, ref: BookRef, temp_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil) 整本下载到 temp_path
---@field materializeWholeAsync fun(self: BookSource, ref: BookRef, temp_path: string, on_progress: (fun(bytes: number)|nil), cb: fun(ok: boolean|nil, err: string|nil)): table|nil
---@field materializeChapter fun(self: BookSource, ref: BookRef, chapter: BookChapter, temp_path: string): (boolean|nil, string|nil)|nil 已废弃：按章阅读改用 fetchChapterContentAsync
---@field materializeChapterAsync fun(self: BookSource, ref: BookRef, chapter: BookChapter, temp_path: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil|nil 已废弃
---@field coverRequest fun(self: BookSource, ref: BookRef): (BookCoverRequest|nil, string|nil) 封面请求描述
---@field localPathFor fun(self: BookSource, ref: BookRef): string|nil 本地源专用：原文件直开路径（存在才返回，命中则不下载不复制）
---@field probeFileSize fun(self: BookSource, ref: BookRef): number|nil 远端/本地文件字节数；未知返回 nil
---@field importBookAsync fun(self: BookSource, local_path: string, filename: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil 书城导入目标（local 移入 / webdav 上传）
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, string|nil) 注册阅读设备（统计前置）
---@field registerReadingDeviceAsync fun(self: BookSource, device_id: string, model: string|nil, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, string|nil) 上报阅读统计
---@field importReadingStatsAsync fun(self: BookSource, payload: BookStatsPayload, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field syncAnnotationsAsync fun(self: BookSource, payload: table, cb: fun(data: table|nil, err: string|nil)): table|nil 同步划线/书签（moon）

return {
    SourceCapabilities = SourceCapabilities,
}
