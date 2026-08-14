---@meta
--- 本文件仅 EmmyLua 类型注释，运行时不要 require。

---@alias SourceId "moon"|"webdav"|"wechat"|string

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
---@field detail boolean
---@field cover boolean
---@field whole_book boolean
---@field chapters boolean
---@field progress_pull boolean
---@field progress_push boolean
---@field insight boolean
---@field stats_import boolean
---@field store boolean

---@alias SourceErrorCode "not_configured"|"unauthorized"|"unsupported"|"offline"|"not_found"|"protocol"|"io"

---@class SourceError
---@field code SourceErrorCode
---@field message string
---@field retryable boolean
---@field cause string|nil

---@class BookFiltersResult
---@field data table|nil

---@class BookStatsBook
---@field md5 string

---@class BookStatsRow
---@field md5 string
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

--- 统一数据源实例接口。失败一律 (data|nil, SourceError|nil)。
---@class BookSource
---@field id SourceId|nil
---@field name string|nil
---@field capabilities fun(self: BookSource): SourceCapabilities
---@field configurationState fun(self: BookSource): SourceConfigurationState
---@field configured fun(self: BookSource): boolean
---@field ping fun(self: BookSource): (table|nil, SourceError|nil)
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, SourceError|nil)
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, SourceError|nil)
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, SourceError|nil)
---@field filters fun(self: BookSource): (BookFiltersResult|nil, SourceError|nil)
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, SourceError|nil)
---@field clearCaches fun(self: BookSource)
---@field close fun(self: BookSource)|nil
---@field getDetail fun(self: BookSource, ref: BookRef): (BookDetail|nil, SourceError|nil)
---@field getProgress fun(self: BookSource, ref: BookRef): (ProgressPosition|nil, SourceError|nil)
---@field putProgress fun(self: BookSource, ref: BookRef, pos: ProgressPosition): (boolean|nil, SourceError|nil)
---@field getToc fun(self: BookSource, ref: BookRef): (BookChapter[]|nil, SourceError|nil)
---@field materializeWhole fun(self: BookSource, ref: BookRef, temp_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, SourceError|nil)
---@field materializeChapter fun(self: BookSource, ref: BookRef, chapter: BookChapter, temp_path: string): (boolean|nil, SourceError|nil)
---@field coverRequest fun(self: BookSource, ref: BookRef): (BookCoverRequest|nil, SourceError|nil)
---@field probeFileSize fun(self: BookSource, ref: BookRef): number|nil
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, SourceError|nil)
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, SourceError|nil)
