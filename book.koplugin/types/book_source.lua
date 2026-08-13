---@meta

--- 数据源能力位。
--- 调用方先查再调；未声明为 true 的能力应返回 nil, 错误串。
--- 仅保留页面实际查询的位：store / stats / chapters。
---@class BookCapabilities
---@field store boolean 是否支持书城 tab（listStore）
---@field chapters boolean 是否按章阅读（getBookDetail / getToc / ensureChapter）

--- filters() 返回的筛选项元数据（图书馆下拉）。
---@class BookFiltersResult
---@field data table|nil 源自定义结构（favorites / categories / groupNames 等）

--- 统计上报：书目行（importReadingStats）。
---@class BookStatsBook
---@field stable_id string 书身份（= Book.id）
---@field title string|nil 书名
---@field authors string|nil 作者

--- 统计上报：单条阅读记录（对齐 KOReader page_stat）。
---@class BookStatsRow
---@field stable_id string 书身份
---@field page number 页码
---@field start_time number 开始时间 unix 秒
---@field duration number 持续秒数
---@field total_pages number 该书总页数
---@field device_id string|nil 设备 id

--- 统计上报请求体。
---@class BookStatsPayload
---@field books BookStatsBook[]|nil 涉及的书目
---@field stats BookStatsRow[]|nil 阅读记录行
---@field device_id string|nil 本机设备 id

--- 封面 HTTP 请求描述；调用方自行下载，源不落盘。
---@class BookCoverRequest
---@field url string 封面 URL
---@field headers table 请求头（Cookie / Referer 等）

--- 统一数据源实例接口。
--- 失败语义：一律 (data|nil, err|nil)；书身份参数一律 stable_id（= Book.id）。
--- 身份见 types/source.lua（SourceId / BookSourceMeta）。
---@class BookSource
---@field capabilities fun(self: BookSource): BookCapabilities 能力位
---@field configured fun(self: BookSource): boolean 是否已配置可用（未配置勿调业务接口）
---@field ping fun(self: BookSource): (table|nil, string|nil) 连通性探测
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 图书馆列表
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 书城列表（需 store）
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil) 最近阅读
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil) 筛选项
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil) 阅读洞察（需 stats）
---@field getProgress fun(self: BookSource, stable_id: string): (BookProgressResult|nil, string|nil) 拉取远端进度
---@field updateProgress fun(self: BookSource, stable_id: string, frac: number, spine: number|nil, page: number|nil, percent_text: string|nil): (table|nil, string|nil) 上报进度；frac∈[0,1]
---@field probeFileSize fun(self: BookSource, stable_id: string): number|nil 探测整本文件大小（下载进度条）
---@field downloadBook fun(self: BookSource, stable_id: string, dest_path: string, on_progress: (fun(bytes: number)|nil)): (boolean|nil, string|nil) 下载整本
---@field coverRequest fun(self: BookSource, stable_id: string): (BookCoverRequest|nil, string|nil) 封面请求描述
---@field getBookDetail fun(self: BookSource, stable_id: string): (BookDetail|nil, string|nil) 书籍详情（需 chapters 或详情页）
---@field getToc fun(self: BookSource, stable_id: string): (BookTocResult|nil, string|nil) 目录（需 chapters）
---@field ensureChapter fun(self: BookSource, stable_id: string, idx: number, dest_path: string, chapter: BookChapter|nil): (boolean|nil, string|nil) 确保章节 epub 落盘
---@field registerReadingDevice fun(self: BookSource, device_id: string, model: string|nil): (table|nil, string|nil) 注册阅读设备
---@field importReadingStats fun(self: BookSource, payload: BookStatsPayload): (table|nil, string|nil) 上报阅读统计
---@field primeRecentCache fun(self: BookSource, limit: number|nil, res: BookListResult|nil) 回填最近阅读内存缓存（子进程结果）
---@field primeInsightCache fun(self: BookSource, res: BookInsightResult|nil) 回填 insight 内存缓存
