---@meta
--- 本文件仅 EmmyLua 类型注释，运行时不要 require。
--- 运行时基类：source.base（SourceBase）
--- 适配器：source.moon / source.wechat / source.webdav
--- 注册表：source.registry
--- 归一化：source.contract

--- 数据源身份 id。
--- 与 registry 注册键、settings.active_source、SourceBase.id 一致。
--- 内置：moon / webdav / wechat；亦可扩展自定义字符串。
---@alias SourceId "moon"|"webdav"|"wechat"|string

--- 数据源展示元信息（设置页切换源、顶栏当前源名）。
--- 由各源模块 meta() 返回；不构造实例即可读取。
---@class BookSourceMeta
---@field id SourceId 源身份，唯一
---@field name string 本地化展示名

--- 数据源能力位。
--- 调用方先查再调；未声明为 true 的能力应返回 nil, 错误串。
--- 仅保留页面实际查询的位：store / stats / chapters。
---@class BookCapabilities
---@field store boolean 是否支持书城 tab（listStore）
---@field stats boolean 是否支持统计 tab（readingInsight）
---@field chapters boolean 是否按章阅读（getBookDetail / getToc / ensureChapter）

--- filters() 返回的筛选项元数据（图书馆下拉）。
---@class BookFiltersResult
---@field data table|nil 源自定义结构（favorites / categories / groupNames 等）

--- 统计上报：书目行（交给 Source；moon 再 md5→filename）。
---@class BookStatsBook
---@field md5 string KOReader statistics content md5

--- 统计上报：单条阅读记录（对齐 KOReader page_stat）。
---@class BookStatsRow
---@field md5 string 对应 BookStatsBook.md5
---@field page number 页码
---@field start_time number 开始时间 unix 秒
---@field duration number 持续秒数
---@field total_pages number 该书总页数
---@field device_id string|nil 设备 id

--- 统计上报请求体（Source 契约；moon 转为 API wire 的 filename）。
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
--- 运行时基类：source.base（SourceBase，实例带 id / name）。
---@class BookSource
---@field id SourceId|nil 源身份（基类实例必有）
---@field name string|nil 展示名
---@field capabilities fun(self: BookSource): BookCapabilities 能力位
---@field configured fun(self: BookSource): boolean 是否已配置可用（未配置勿调业务接口）
---@field ping fun(self: BookSource): (table|nil, string|nil) 连通性探测
---@field listLibrary fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 图书馆列表
---@field listStore fun(self: BookSource, opts: BookListOpts|nil): (BookListResult|nil, string|nil) 书城列表（需 store）
---@field recentBooks fun(self: BookSource, limit: number|nil): (BookListResult|nil, string|nil) 最近阅读
---@field filters fun(self: BookSource): (BookFiltersResult|nil, string|nil) 筛选项
---@field readingInsight fun(self: BookSource): (BookInsightResult|nil, string|nil) 阅读洞察（需 stats）
---@field clearCaches fun(self: BookSource) 清 HTTP URL 缓存（强制刷新）
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
