--- Source 接口与能力表。可 require：仅 SourceCapabilities.defaults 为运行时。

---@alias SourceId "moon"|"webdav"|"wechat"|"rss"|"local"|string

---@class BookSourceMeta
---@field id SourceId
---@field name string
---@field preview boolean|nil 实验源；未完成前不进正式列表

--- 能力是用户可用功能，不是「模块里有没有函数」。
---@class SourceCapabilities
---@field library boolean
---@field recent boolean
---@field search boolean
---@field filters boolean
---@field refresh boolean 支持手动强制重扫书库（本地源）
---@field detail boolean
---@field scrape boolean 支持把外部元数据写入本地书籍记录
---@field cover boolean
---@field whole_book boolean
---@field chapters boolean
---@field progress_pull boolean
---@field progress_push boolean
---@field insight boolean
---@field stats_import boolean
---@field store boolean

local SourceCapabilities = {}

--- 返回全 false 的默认能力表。
---@return SourceCapabilities
function SourceCapabilities.defaults()
    return {
        library = false,
        recent = false,
        search = false,
        filters = false,
        refresh = false,
        detail = false,
        scrape = false,
        cover = false,
        whole_book = false,
        chapters = false,
        progress_pull = false,
        progress_push = false,
        insight = false,
        stats_import = false,
        store = false,
    }
end

---@class BookFiltersResult
---@field data table|nil

---@class BookStatsBook
---@field stable_id string

---@class BookStatsRow
---@field stable_id string
---@field page number
---@field start_time number
---@field duration number
---@field total_pages number
---@field device_id string|nil

---@class BookStatsPayload
---@field books BookStatsBook[]|nil
---@field stats BookStatsRow[]|nil
---@field device_id string|nil

---@class BookCoverRequest
---@field url string
---@field headers table

---@alias SourceConfigurationState "ready"|"needs_login"|"needs_config"|"unavailable"

--- 按章正文载荷：Source 只交内容，宿主写 HTML。
---@class ChapterContentPayload
---@field title string|nil
---@field html string|nil HTML/XHTML 正文片段（优先）
---@field text string|nil 纯文本（无 html 时由宿主转段落）

--- 统一数据源实例接口。失败一律 (data|nil, string|nil)。
---@class BookSource
---@field id SourceId|nil
---@field name string|nil
---@field onEvent fun(self: BookSource, event: string, payload: table|nil)|nil 生命周期事件（见 source.base 注释）
---@field capabilities fun(self: BookSource): SourceCapabilities
---@field configurationState fun(self: BookSource): SourceConfigurationState
---@field configured fun(self: BookSource): boolean
---@field ping fun(self: BookSource): (table|nil, string|nil)
---@field pingAsync fun(self: BookSource, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field listLibraryAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field listStoreAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil)
---@field recentBooksAsync fun(self: BookSource, limit: number|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil)
---@field filtersAsync fun(self: BookSource, cb: fun(data: BookFiltersResult|nil, err: string|nil)): table|nil
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil)
---@field readingInsightAsync fun(self: BookSource, cb: fun(data: BookInsightResult|nil, err: string|nil)): table|nil
---@field clearCaches fun(self: BookSource)
---@field close fun(self: BookSource)|nil
---@field getDetail fun(self: BookSource, ref: BookRef): (BookDetail|nil, string|nil)
---@field getDetailAsync fun(self: BookSource, ref: BookRef, cb: fun(data: BookDetail|nil, err: string|nil)): table|nil
---@field getProgress fun(self: BookSource, ref: BookRef): (ProgressPosition|nil, string|nil)
---@field getProgressAsync fun(self: BookSource, ref: BookRef, cb: fun(data: ProgressPosition|nil, err: string|nil)): table|nil
---@field putProgress fun(self: BookSource, ref: BookRef, pos: ProgressPosition): (boolean|nil, string|nil)
---@field putProgressAsync fun(self: BookSource, ref: BookRef, pos: ProgressPosition, cb: fun(ok: boolean|nil, err: string|nil)): table|nil
---@field getToc fun(self: BookSource, ref: BookRef): (BookChapter[]|nil, string|nil)
---@field getTocAsync fun(self: BookSource, ref: BookRef, cb: fun(data: BookChapter[]|nil, err: string|nil)): table|nil
---@field fetchChapterContentAsync fun(self: BookSource, ref: BookRef, chapter: BookChapter, cb: fun(payload: ChapterContentPayload|nil, err: string|nil)): table|nil
---@field materializeWhole fun(self: BookSource, ref: BookRef, temp_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil)
---@field materializeWholeAsync fun(self: BookSource, ref: BookRef, temp_path: string, on_progress: (fun(bytes: number)|nil), cb: fun(ok: boolean|nil, err: string|nil)): table|nil
---@field materializeChapter fun(self: BookSource, ref: BookRef, chapter: BookChapter, temp_path: string): (boolean|nil, string|nil)|nil 已废弃：按章阅读改用 fetchChapterContentAsync
---@field materializeChapterAsync fun(self: BookSource, ref: BookRef, chapter: BookChapter, temp_path: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil|nil 已废弃
---@field coverRequest fun(self: BookSource, ref: BookRef): (BookCoverRequest|nil, string|nil)
---@field localPathFor fun(self: BookSource, ref: BookRef): string|nil 本地源专用：原文件直开路径（存在才返回，命中则不下载不复制）
---@field probeFileSize fun(self: BookSource, ref: BookRef): number|nil
---@field importBookAsync fun(self: BookSource, local_path: string, filename: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil 书城导入目标（local 移入 / webdav 上传）
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, string|nil)
---@field registerReadingDeviceAsync fun(self: BookSource, device_id: string, model: string|nil, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, string|nil)
---@field importReadingStatsAsync fun(self: BookSource, payload: BookStatsPayload, cb: fun(data: table|nil, err: string|nil)): table|nil
---@field syncAnnotationsAsync fun(self: BookSource, payload: table, cb: fun(data: table|nil, err: string|nil)): table|nil

return {
    SourceCapabilities = SourceCapabilities,
}
