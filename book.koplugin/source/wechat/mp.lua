--[[--
微信读书公众号（订阅页用）：公众号列表、文章分页、文章页 → 正文。

列表走 ``/web/mp/articles``（每次实测最多回 20 篇），正文走 ``/web/mp/content`` 的文章页 HTML，
普通图文取 ``#js_content``，图片 / 纯文字消息取脚本里的正文。

@module koplugin.book.source.wechat.mp
--]]

local Auth = require("source.wechat.auth")
local Assets = require("source.wechat.assets")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Mp = {}

local WEB = "https://weread.qq.com"
--- 文章页超过这么大不解析：页面自带几 MB 脚本（实测 2–4 MB），再大多半是异常页面，别撑爆内存。
local MAX_HTML = 8 * 1024 * 1024
--- 每篇最多落地的图片数；多出的直接去掉，免得一篇文章下几十 MB。
local MAX_IMAGES = 30
--- 公众号 CDN 的宽度档位（URL 末段），640 够墨水屏看清，原图（0）动辄几 MB。
local IMAGE_WIDTH = "640"
--- 公众号接口回 -2041 时的提示（订阅刷新据此弹窗，网页端作为源的错误显示）。
Mp.AUTH_EXPIRED = "公众号授权已失效，请在微信读书 App 中打开任意公众号重新授权后再试"
--- 每页篇数（服务端实测最多回 20）。
Mp.PAGE = 20

--- 是否公众号 bookId。
---@param book_id string|nil
---@return boolean
function Mp.isMp(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

--- 旧版本把书架上的公众号同步进了书库：撕掉这些 books 行（连同依附记录）。
--- 公众号只属于订阅；书架映射（mapper.shelfList）已不再产出，这里只清历史遗留，幂等。
---@param BookDB table book.books_db
---@return integer removed
function Mp.dropLegacyBooks(BookDB)
    local n = 0
    for _idx, id in ipairs(BookDB.stableIdsBySource("wechat") or {}) do
        if Mp.isMp(id) then
            BookDB.remove("wechat", id)
            n = n + 1
        end
    end
    return n
end

--- /web/mp/articles 回包 → 文章列表（新到旧）。
---@param data table ``{ reviews = { { createTime, subReviews = { { reviewId, review = { mpInfo } } } } } }``
---@return { guid: string, title: string, time: integer }[]
function Mp.articles(data)
    local out, seen = {}, {}
    for _g, group in ipairs(type(data) == "table" and type(data.reviews) == "table" and data.reviews or {}) do
        for _s, sub in ipairs(type(group) == "table" and type(group.subReviews) == "table" and group.subReviews or {}) do
            local review = type(sub) == "table" and (type(sub.review) == "table" and sub.review or sub) or {}
            local info = type(review.mpInfo) == "table" and review.mpInfo or {}
            local uid = tostring(review.reviewId or sub.reviewId or "")
            if uid ~= "" and not seen[uid] then
                seen[uid] = true
                local time = tonumber(review.createTime or group.createTime) or 0
                local title = type(info.title) == "string" and info.title ~= "" and info.title
                    or os.date("%Y-%m-%d", time)
                out[#out + 1] = { guid = uid, title = title, time = time }
            end
        end
    end
    table.sort(out, function(a, b) return a.time > b.time end)
    return out
end

--- 书架 wire 里的公众号 → ``{ id, title, group }``；group 取用户自建分组（archive）名。
--- 公众号可能在 books 行里，也可能在 mp / mpBook / officialAccounts（mp 实测是 ``{ book = 单个对象 }``）。
---@param shelf table
---@return { id: string, title: string, group: string }[]
function Mp.accounts(shelf)
    shelf = type(shelf) == "table" and shelf or {}
    local groups = require("source.wechat.mapper").groupByBookId(shelf)
    local out, seen = {}, {}
    local function add(rows)
        if type(rows) ~= "table" then return end
        if rows.book ~= nil then rows = rows.book end
        if rows.bookId ~= nil then rows = { rows } end
        for _idx, row in ipairs(rows) do
            local book = type(row) == "table" and (type(row.bookInfo) == "table" and row.bookInfo
                or type(row.book) == "table" and row.book or row) or {}
            local id = tostring(book.bookId or "")
            if Mp.isMp(id) and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, title = tostring(book.title or id), group = groups[id] or "" }
            end
        end
    end
    for _idx, wire in ipairs({ shelf, type(shelf.data) == "table" and shelf.data or {} }) do
        for _i, key in ipairs({ "books", "mp", "mpBook", "officialAccounts" }) do add(wire[key]) end
    end
    return out
end

--- 公众号图片：懒加载地址换成 src，宽度降到 640 档、去掉 webp 转码参数；超出上限的图去掉。
--- 标签重建成只剩 src：原标签的固定宽高 / 内联样式在墨水屏上只会撑破版面。
---@param html string
---@return string
local function rewriteImages(html)
    local count = 0
    return (html:gsub("<img%s[^>]*>", function(tag)
        local _q, src = tag:match('data%-src=(["\'])(.-)%1')
        if not src then _q, src = tag:match('%ssrc=(["\'])(.-)%1') end
        if not src or src == "" or count >= MAX_IMAGES then return "" end
        -- QQ 表情是透明占位图 + CSS 雪碧背景，下载下来只是空白：去掉，留 alt（如「[微笑]」）
        if src:find("pic_blank.gif", 1, true) then
            local _qa, alt = tag:match('%salt=(["\'])(.-)%1')
            return alt or ""
        end
        count = count + 1
        src = src:gsub("&amp;", "&")
        if src:find("mmbiz.qpic.cn", 1, true) then
            src = src:gsub("/0([%?#])", "/" .. IMAGE_WIDTH .. "%1"):gsub("/0$", "/" .. IMAGE_WIDTH)
                :gsub("([%?&])tp=webp&?", "%1"):gsub("[%?&]$", "")
        end
        return '<img src="' .. Text.xmlEscape(src) .. '"/>'
    end))
end

--- 码点 → UTF-8（含 BMP 以外的 emoji）。
---@param code integer
---@return string
local function utf8Char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

local ESCAPES = { n = "\n", r = "", t = "\t" }

--- 页面脚本里 ``key: '…'`` 的单引号 JS 字符串，解开 \xHH / \uXXXX / \n 等转义；没有返回 nil。
---@param html string
---@param key string
---@return string|nil
local function jsString(html, key)
    local _s, e = html:find(key .. "%s*:%s*'")
    if not e then return nil end
    local out, i = {}, e + 1
    while true do
        local j = html:find("[\\']", i)
        if not j then return nil end
        out[#out + 1] = html:sub(i, j - 1)
        if html:sub(j, j) == "'" then break end
        local c = html:sub(j + 1, j + 1)
        local hex = c == "x" and html:sub(j + 2, j + 3):match("^%x%x$")
        local uni = c == "u" and html:sub(j + 2, j + 5):match("^%x%x%x%x$")
        if hex then
            out[#out + 1], i = string.char(tonumber(hex, 16)), j + 4
        elseif uni then
            local code = tonumber(uni, 16)
            -- emoji 在 JS 里是代理对「\uD83D\uDE00」：两半合成一个码点，分开编码会成非法 UTF-8（显示为空 / 乱码）
            local low = code >= 0xD800 and code < 0xDC00 and html:sub(j + 6, j + 7) == "\\u"
                and tonumber(html:sub(j + 8, j + 11):match("^%x%x%x%x$") or "", 16)
            if low and low >= 0xDC00 and low < 0xE000 then
                out[#out + 1], i = utf8Char(0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)), j + 12
            else
                out[#out + 1], i = utf8Char(code), j + 6
            end
        else
            out[#out + 1], i = ESCAPES[c] or c, j + 2
        end
    end
    return table.concat(out)
end

--- 图片 / 纯文字消息（item_show_type 8、10）没有 ``#js_content``：
--- 正文在脚本里的 ``content_noencode``（纯文字或 HTML），图片在 ``picture_page_info_list`` 的 ``cdn_url``。
---@param html string
---@return string|nil
local function scriptBody(html)
    local text = jsString(html, "content_noencode")
    local parts = {}
    if text and not text:match("^%s*$") then
        parts[1] = text:find("<", 1, true) and text or Text.textToBody(text)
    end
    local list = html:find("picture_page_info_list%s*:%s*%[")
    if list then
        local stop = html:find("}%s*%]", list) or #html
        for url in html:sub(list, stop):gmatch("cdn_url%s*:%s*'([^']+)'") do
            -- 地址是 JS 字符串：「\x26amp;」解成「&amp;」（属性里正好是转义后的 &）
            url = url:gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            parts[#parts + 1] = '<p><img src="' .. url .. '"/></p>'
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

--- 文章页 HTML → 正文片段：普通图文取 ``#js_content``，图片 / 纯文字消息取脚本里的正文与图片；
--- 去脚本、样式、svg，剥掉内联字号（字号交回阅读器设置）。
---@param html string
---@return string|nil
function Mp.extractBody(html)
    html = tostring(html or "")
    -- 先按 id 定位再切片：页面前面几 MB 的脚本 / 样式不进后面的匹配与 gsub。
    local at = html:find('id="js_content"', 1, true)
    local start = at and html:sub(math.max(1, at - 512), at):match(".*()<div")
    local body
    if start then
        local from = math.max(1, at - 512) + start - 1
        local tail = html:sub(from)
        body = tail:match('^<div[^>]*>(.-)</div>%s*<script') or tail:match('^<div[^>]*>(.*)')
    end
    if not body or body:match("^%s*$") then body = scriptBody(html) end
    if not body or body:match("^%s*$") then return nil end
    body = body:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
        :gsub("<svg.-</svg>", ""):gsub("<svg[^>]*/>", "")
    body = body:gsub("(%sstyle=)([\"'])(.-)%2", function(prefix, quote, css)
        css = css:gsub("font%-size%s*:[^;]*;?", "")
        if css:match("^%s*$") then return "" end
        return prefix .. quote .. css .. quote
    end)
    -- emoji 一律去掉：KOReader 字体画不出（只会成方块）。旧版雪碧图空 span 直接删，正文里的码点交给 stripEmoji。
    body = body:gsub('<span[^>]-class="emoji emoji%x+"[^>]*>%s*</span>', "")
    return Text.stripEmoji(rewriteImages(body))
end

--- 网页端 /web/login/renewal 回包头里的公众号凭据（x-wr-ticket / x-wrpa-0）：缺了会被风控回 -2041 或「验证」页。
--- 只在内存里留：进程重启后第一次被拒时再续一次。
local mp_headers = {}

--- 续期公众号凭据并记下回包里的 ticket / wrpa 头；失败也回调（调用方照旧重试，由重试结果判生死）。
---@param cb fun()
---@return { cancel: fun() }|nil
function Mp.renewAsync(cb)
    return Auth.webPostAsync(WEB .. "/web/login/renewal", '{"rq":"%2Fweb%2Fbook%2Fread","ql":false}',
        { skip_auth_retry = true }, function(_raw, _err, res)
            for _idx, name in ipairs({ "x-wr-ticket", "x-wrpa-0" }) do
                local value = Request.header(res, name)
                if value and value ~= "" then mp_headers[name] = value end
            end
            cb()
        end)
end

--- 带公众号凭据头的 GET；回 -2041 时续期一次再重试。
---@param url string
---@param opts table
---@param cb fun(raw: string|nil, err: any, res: table|nil)
---@return { cancel: fun() }
local function mpGetAsync(url, opts, cb)
    local cancelled, job = false, nil
    local function go(renewed)
        local headers = {}
        for k, v in pairs(opts.headers or {}) do headers[k] = v end
        for k, v in pairs(mp_headers) do headers[k] = v end
        local sent = {}
        for k, v in pairs(opts) do sent[k] = v end
        sent.headers = headers
        job = Auth.webGetAsync(url, sent, function(raw, err, res)
            if cancelled then return end
            -- 会话层续期重试后仍被拒时 raw 为 nil、res.json 也没填，回包只在 res.body 里
            local data = res and res.json
            if data == nil and res and res.body and res.body:find("2041", 1, true) then
                local ok, decoded = pcall(require("utils.json").decode, res.body)
                data = ok and decoded or nil
            end
            if not renewed and type(data) == "table" and tonumber(data.errcode or data.errCode) == -2041 then
                job = Mp.renewAsync(function() if not cancelled then go(true) end end)
                return
            end
            cb(raw, err, res)
        end)
    end
    go(false)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 一页文章列表；offset 当 maxIdx 传（已拉到的篇数）。只传 offset 不带 maxIdx/count 时服务端回 errCode -2041。
---@param book_id string MP_WXS_ 开头
---@param offset integer
---@param cb fun(items: table[]|nil, err: any)
---@return { cancel: fun() }|nil
function Mp.fetchArticlesAsync(book_id, offset, cb)
    local url = WEB .. "/web/mp/articles?" .. Text.formEncode({ bookId = book_id, maxIdx = offset or 0, count = Mp.PAGE })
    return mpGetAsync(url, { no_expire = true }, function(raw, err, res)
        -- 会话层已为判失效解过的直接用，只解一次；utils.json 修好标题里 emoji 的代理对。
        local data = res and res.json
        local body = raw or (res and res.body)
        if data == nil and body then
            local ok, decoded = pcall(require("utils.json").decode, body)
            data = ok and decoded or nil
        end
        -- -2041（续期后仍是）：公众号授权失效，要在 App 里重新授权；不判登录失效
        if type(data) == "table" and tonumber(data.errcode or data.errCode) == -2041 then
            cb(nil, _(Mp.AUTH_EXPIRED))
            return
        end
        if not raw or type(data) ~= "table" then
            cb(nil, err or _("返回非 JSON"))
            return
        end
        if tonumber(data.errcode or data.errCode or 0) ~= 0 then
            cb(nil, data.errmsg or data.errMsg or _("加载失败"))
            return
        end
        cb(Mp.articles(data))
    end)
end

--- 文章页遇「验证」页时的最多请求次数。
Mp.VERIFY_TRIES = 3

--- 延迟执行（测试可替换）。
---@param sec number
---@param fn fun()
function Mp.later(sec, fn)
    require("ui/uimanager"):scheduleIn(sec, fn)
end

--- 一篇文章的正文片段：拉文章页、抽正文；images_dir 非 nil 时图片落地（不带会话 Cookie）。
---@param review_id string
---@param images_dir string|nil
---@param cb fun(html: string|nil, err: any)
---@return { cancel: fun() }
function Mp.fetchContentAsync(review_id, images_dir, cb)
    local cancelled, job, tries = false, nil, 0
    local fetch
    fetch = function()
        tries = tries + 1
        job = mpGetAsync(WEB .. "/web/mp/content?reviewId=" .. Text.urlEncode(tostring(review_id or "")), {
            accept = "text/html,application/xhtml+xml,*/*",
            no_expire = true, -- 公众号接口被风控回失效 errcode 时不判整个微信读书登录失效
            headers = { ["Referer"] = WEB .. "/" },
            timeout = require("http.timeout").net(3),
        }, function(raw, err)
            if cancelled then return end
            if not raw then
                cb(nil, err or _("正文获取失败"))
                return
            end
            if #raw > MAX_HTML then
                cb(nil, _("文章太大，无法显示"))
                return
            end
            local body = Mp.extractBody(raw)
            -- 短时间连着拉文章页（如自动离线下载正在跑）会返回「验证」反爬页：退避几秒再拉，最多 VERIFY_TRIES 次。
            local verify = not body and raw:find("<title>%s*验证%s*</title>") ~= nil
            raw = nil
            if verify and tries < Mp.VERIFY_TRIES then
                local function retry() Mp.later(2 * tries, function() if not cancelled then fetch() end end) end
                -- 第一次被拦先续期拿 ticket / wrpa，再退避重拉
                if tries == 1 then
                    job = Mp.renewAsync(retry)
                else
                    job = nil
                    retry()
                end
                return
            end
            if not body then
                cb(nil, verify and _("微信读书要求验证，请稍后再试") or _("正文解析失败"))
                return
            end
            if not images_dir then
                cb(body)
                return
            end
            job = Assets.localizeArticleAsync(images_dir, body, function(localized)
                if not cancelled then cb(localized) end
            end)
        end)
    end
    fetch()
    return { cancel = function()
            cancelled = true
            if job and job.cancel then job:cancel() end
        end }
end

return Mp
