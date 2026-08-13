---@meta

---@alias MoonSourceId "moon"|"webdav"|"wechat"|string

--- 数据源能力位。调用方先查再调；未声明为 true 的能力应返回 nil, 错误串。
---@class BookCapabilities
---@field store boolean 书城 tab：listStore
---@field stats boolean 统计 tab：readingInsight
---@field chapters boolean 按章阅读：getBookDetail、getToc、ensureChapter

--- 注册表展示用元信息（非实例方法）
---@class BookSourceMeta
---@field id MoonSourceId
---@field name string

--- 筛选项元数据
---@class BookFiltersResult
---@field data table|nil

--- 统计上报：书目行
---@class BookStatsBook
---@field stable_id string
---@field title string|nil
---@field authors string|nil

--- 统计上报：阅读记录行（KOReader page_stat 语义）
---@class BookStatsRow
---@field stable_id string
---@field page number
---@field start_time number
---@field duration number
---@field total_pages number
---@field device_id string|nil

--- 统计上报体
---@class BookStatsPayload
---@field books BookStatsBook[]|nil
---@field stats BookStatsRow[]|nil
---@field device_id string|nil

--- 封面 HTTP 描述；调用方自行下载，源不落盘
---@class BookCoverRequest
---@field url string
---@field headers table

--- 统一数据源实例。失败语义：一律 (data|nil, err|nil)。
--- 书身份参数一律 stable_id（= Book.id）。
---@class BookSource
---@field capabilities fun(self: BookSource): BookCapabilities
---@field configured fun(self: BookSource): boolean
---@field ping fun(self: BookSource): (table|nil, string|nil)
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil)
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil)
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil)
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil)
---@field clearCaches fun(self: BookSource)
---@field getProgress fun(self: BookSource, stable_id: string): (BookProgressResult|nil, string|nil)
---@field updateProgress fun(self: BookSource, stable_id: string, frac: number, spine: number|nil, page: number|nil, percent_text: string|nil): (table|nil, string|nil)
---@field probeFileSize fun(self: BookSource, stable_id: string): number|nil
---@field downloadBook fun(self: BookSource, stable_id: string, dest_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil)
---@field coverRequest fun(self: BookSource, stable_id: string): (BookCoverRequest|nil, string|nil)
---@field getBookDetail fun(self: BookSource, stable_id: string): (BookDetail|nil, string|nil)
---@field getToc fun(self: BookSource, stable_id: string): (BookTocResult|nil, string|nil)
---@field ensureChapter fun(self: BookSource, stable_id: string, idx: number, dest_path: string, chapter: BookChapter|nil): (boolean|nil, string|nil)
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, string|nil)
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, string|nil)
---@field primeRecentCache fun(self: BookSource, limit: number|nil, res: BookListResult|nil)
---@field primeInsightCache fun(self: BookSource, res: BookInsightResult|nil)
