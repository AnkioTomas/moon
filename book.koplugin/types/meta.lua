---@meta koplugin.book.types
--- EmmyLua / LuaLS 类型面：仅 IDE，不参与运行时 require。

------------------------------------------------------------
-- 通用设置 / 数据源凭证
------------------------------------------------------------

---@alias MoonHomeHeader "clock"|"hitokoto"
---@alias MoonSourceId "moon"|"webdav"|"wechat"|"legado"|string

---@class MoonCommonSettings
---@field active_source MoonSourceId
---@field auto_sync boolean
---@field auto_stats boolean
---@field home_header MoonHomeHeader
---@field ui_scale number
---@field reader_float_menu boolean
---@field open_on_start boolean|nil

---@class MoonSourceConfig
---@field base_url string|nil
---@field token string|nil

------------------------------------------------------------
-- Source 契约
------------------------------------------------------------

---@class BookCapabilities
---@field store boolean
---@field stats boolean
---@field progress_sync boolean
---@field stats_import boolean
---@field search boolean
---@field filters boolean

---@class BookSourceMeta
---@field id MoonSourceId
---@field name string

--- 统一书籍字段；适配器可保留服务端别名（bookName 等）
---@class Book
---@field id string|nil
---@field title string|nil
---@field authors string|nil
---@field author string|nil
---@field cover_id string|nil
---@field progress number|nil
---@field finished boolean|nil
---@field extra any
---@field filename string|nil
---@field fileName string|nil
---@field file string|nil
---@field path string|nil
---@field name string|nil
---@field bookName string|nil
---@field progressPercent number|string|nil
---@field description string|nil
---@field intro string|nil
---@field summary string|nil

---@class BookListOpts
---@field page number|nil
---@field pageSize number|nil
---@field search string|nil
---@field series string|nil
---@field category string|nil
---@field favorite string|nil
---@field finished string|nil
---@field author string|nil

---@class BookListResult
---@field code number|nil
---@field msg string|nil
---@field count number|nil
---@field data Book[]|nil
---@field list Book[]|nil
---@field books Book[]|nil

---@class BookFiltersResult
---@field code number|nil
---@field msg string|nil
---@field data table|nil

---@class BookLibraryStats
---@field code number|nil
---@field msg string|nil
---@field data table|nil

---@class BookProgressResult
---@field code number|nil
---@field msg string|nil
---@field data table|nil

---@class BookInsightResult
---@field code number|nil
---@field msg string|nil
---@field data table|nil

---@class BookHitokotoRow
---@field hitokoto string
---@field from string|nil
---@field from_who string|nil

---@class BookHitokotoResult
---@field code number
---@field data BookHitokotoRow

---@class BookStatsPayload
---@field books table[]|nil
---@field stats table[]|nil
---@field device_id string|nil

--- 统一数据源实例（moon / webdav / …）
---@class BookSource
---@field capabilities fun(self: BookSource): BookCapabilities
---@field configured fun(self: BookSource): boolean
---@field ping fun(self: BookSource): (table|nil, string|nil)
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil)
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil)
---@field libraryStats fun(self: BookSource): (BookLibraryStats|nil, string|nil)
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil)
---@field clearCaches fun(self: BookSource)
---@field getProgress fun(self: BookSource, filename: string): (BookProgressResult|nil, string|nil)
---@field updateProgress fun(self: BookSource, filename: string, frac: number, spine: number|nil, page: number|nil, percent_text: string|nil): (table|nil, string|nil)
---@field probeFileSize fun(self: BookSource, filename: string): number|nil
---@field downloadBook fun(self: BookSource, filename: string, dest_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil)
---@field downloadCover fun(self: BookSource, filename: string, dest_path: string): (boolean|nil, string|nil)
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, string|nil)
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, string|nil)
---@field primeRecentCache fun(self: BookSource, limit: number|nil, res: BookListResult|nil)
---@field primeInsightCache fun(self: BookSource, res: BookInsightResult|nil)
---@field hitokoto fun(self: BookSource): (BookHitokotoResult|nil, string|nil)

------------------------------------------------------------
-- Moon HTTP 客户端
------------------------------------------------------------

---@class MoonApi
---@field base_url string
---@field token string
---@field new fun(self: MoonApi, o: MoonSourceConfig|nil): MoonApi
---@field configured fun(self: MoonApi): boolean
---@field ping fun(self: MoonApi): (table|nil, string|nil)
---@field listBooks fun(self: MoonApi, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field recentBooks fun(self: MoonApi, limit: number|nil): (BookListResult|nil, string|nil)
---@field filters fun(self: MoonApi): (BookFiltersResult|nil, string|nil)
---@field stats fun(self: MoonApi): (BookLibraryStats|nil, string|nil)
---@field registerReadingDevice fun(self: MoonApi, device_id: string, model: string|nil): (table|nil, string|nil)
---@field importReadingStats fun(self: MoonApi, payload: BookStatsPayload|nil): (table|nil, string|nil)
---@field readingInsight fun(self: MoonApi): (BookInsightResult|nil, string|nil)
---@field getProgress fun(self: MoonApi, filename: string): (BookProgressResult|nil, string|nil)
---@field updateProgress fun(self: MoonApi, filename: string, frac: number, spine: number|nil, page: number|nil, percent_text: string|nil): (table|nil, string|nil)
---@field probeFileSize fun(self: MoonApi, filename: string): number|nil
---@field downloadBook fun(self: MoonApi, filename: string, dest_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil)
---@field downloadCover fun(self: MoonApi, filename: string, dest_path: string): (boolean|nil, string|nil)

------------------------------------------------------------
-- Async
------------------------------------------------------------

---@class MoonAsyncOpts
---@field delay number|nil

---@alias MoonAsyncCancel fun()
