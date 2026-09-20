---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。
--- 对应表 http：HTTP 响应缓存；以及 http.request / http.turbo 的请求面。

---@class Http
---@field key string PRIMARY KEY 缓存键
---@field value string 缓存内容
---@field expires integer 过期时间戳
---@field source_id string|nil

--- get/post 第二参。url 是第一参，这里不准带。
---@class HttpRequestOpts
---@field headers table|nil
---@field timeout number|nil 请求超时秒；get/post 也认 block_timeout
---@field block_timeout number|nil timeout 别名（get/post）
---@field connect_timeout number|nil 默认 10
---@field allow_redirects boolean|nil 显式 true 才跟 301/302
---@field auth_username string|nil
---@field auth_password string|nil
---@field user string|nil auth_username 别名（get/post）
---@field password string|nil auth_password 别名（get/post）
---@field accept string|nil get/post 默认 Accept
---@field content_type string|nil POST body 的 Content-Type
---@field on_progress fun(bytes: number)|nil 仅 download
---@field max_bytes number|nil 仅 download；超限失败
---@field cache_ttl number|nil 仅 GET；>0 时走 http.cache，秒
---@field query table|nil 仅参与 cache 键；url 已带 query 时可省略

--- request / stream / download：一张表，必须带 url。
---@class HttpRequest : HttpRequestOpts
---@field url string
---@field method string|nil 默认 GET
---@field body string|nil

--- 未完成的请求句柄。cancel 幂等。
---@class HttpJob : CancelHandle

--- Request.stream 的增量回调。
---@class HttpStreamHandlers
---@field on_headers fun(code: any, headers: any)|nil
---@field on_data fun(chunk: string)|nil
---@field on_done fun(err: any)|nil err 为 nil 表示收完
