--[[--
微信读书章节正文：本地生成 psvts → 拉 e_0/e_1/e_3（或 t_0/t_1）→ 解码。

对齐 weread 网页端通道。EPUB 章节交出服务端 XHTML 原文，除资源本地化（插图、脚注图标、
整书样式表）和脚注接弹窗外不改一个字节；
不写盘、不打 EPUB。个人划线通过 bookmarklist 同步为 KOReader 原生注解。

@module koplugin.book.source.wechat.chapter
--]]

local JSON = require("json")
local logger = require("utils.log")
local Auth = require("source.wechat.auth")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")
local Assets = require("source.wechat.assets")
local Text = require("utils.text")
local _ = require("gettext")

local Chapter = {}

--- e_0 回 "{}" 的重试：服务端对正常可读的章节也会偶发回空对象（同一章几秒后再拉就有正文），
--- 按指数退避重拉（0.5s 起翻倍、单次封顶 8s、加少量抖动），最多 EMPTY_RETRIES 次；仍为空才算失败。
local EMPTY_RETRIES = 10
local EMPTY_RETRY_BASE = 0.5
local EMPTY_RETRY_CAP = 8
local EMPTY_RETRY_JITTER = 0.2

--- 第 n 次重试（从 0 计）前的等待秒数。
---@param n integer
---@return number
function Chapter._retryDelay(n)
    return math.min(EMPTY_RETRY_CAP, EMPTY_RETRY_BASE * 2 ^ n) + math.random() * EMPTY_RETRY_JITTER
end

--- 延时执行；测试可替换。
---@param sec number
---@param fn fun()
function Chapter._schedule(sec, fn)
    require("ui/uimanager"):scheduleIn(sec, fn)
end

--- 请求一个正文分片端点；空对象回包（"{}"）按失败处理，交由调用方换端点重试。
--- st=0 回正文；st=1 回整书样式表（e_0/e_1/e_3 拼起来、或单独 e_2 都是同一份），实测。
---@param bookId string
---@param uid string
---@param psvts string
---@param endpoint string 正文接口路径
---@param style boolean
---@param done fun(raw: string|nil, err: any) 原始 JSON 串
---@return { cancel: fun() }|nil
local function requestShard(bookId, uid, psvts, endpoint, style, done)
    local params = Protocol.contentParams(bookId, uid, psvts, { sc = 1, style = style })
    return Auth.webPostAsync(
        "https://weread.qq.com" .. endpoint,
        JSON.encode(params),
        {
            accept = "application/json, text/plain, */*",
            content_type = "application/json;charset=UTF-8",
            headers = {
                ["Origin"] = "https://weread.qq.com",
                ["Referer"] = Protocol.readerUrl(bookId, uid),
            },
            timeout = require("http.timeout").net(3),
        },
        function(raw, err)
            if not raw then
                done(nil, err or (endpoint .. " failed"))
            elseif raw == "{}" then
                done(nil, endpoint .. " empty")
            else
                done(raw)
            end
        end
    )
end

--- 整书样式表（章节 link 指向的 ../Styles/stylesheets.css）；失败回 nil，由调用方保留原 link。
---@param bookId string
---@param uid string
---@param done fun(css: string|nil)
---@return { cancel: fun() }|nil
local function fetchStyleAsync(bookId, uid, done)
    return requestShard(bookId, uid, Context.reader(bookId, uid).psvts, "/web/book/chapter/e_2", true,
        function(raw, err)
            local css = raw and Protocol.decodeShards(raw)
            if not css or css:find("^%s*<") then
                logger.warn("weread stylesheet fetch", bookId, uid, err)
                done(nil)
                return
            end
            done(css)
        end)
end

--- 异步拉取章节 HTML 正文。
--- 第三个回调参数是划线 range 的坐标原文：EPUB 为解码后的完整 xhtml，TXT 为解码后的纯文本
--- （format 分别为 "html" / "txt"）；不能用清理或段落化后的正文，否则 range 整体偏移。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(html: string|nil, err: any, range_source: string|nil, format: '"html"'|'"txt"'|nil)
---@return { cancel: fun() }
function Chapter.fetchHtmlAsync(bookId, chapter, cb)
    local uid = chapter.uid
    if type(uid) ~= "string" or uid == "" then
        cb(nil, _("章节缺少 uid"))
        return { cancel = function() end }
    end
    local cancelled = false
    local active_job
    local psvts = Context.reader(bookId, uid).psvts
    --- 中止取正文：置位取消标记并终止在途请求。
    local function cancel()
        cancelled = true
        if active_job then active_job:cancel() end
    end
    --- 以错误收尾；已取消则丢弃。
    ---@param err any 失败原因
    local function fail(err)
        if not cancelled then cb(nil, err) end
    end
    --- 取一个正文分片（st=0）；已取消则丢弃回包。
    ---@param endpoint string 正文接口路径
    ---@param done fun(raw: string|nil, err: any) 原始 JSON 串
    local seq = 0
    local function shard(endpoint, done)
        seq = seq + 1
        local mine = seq
        local handle = requestShard(bookId, uid, psvts, endpoint, false, function(raw, err)
            if not cancelled then done(raw, err) end
        end)
        -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它（同 http/mirror）。
        if seq == mine then active_job = handle end
    end
    local function onE0(e0, e0err, tries)
        if not e0 then
            if tries < EMPTY_RETRIES and e0err == "/web/book/chapter/e_0 empty" then
                logger.dbg("weread chapter e_0 empty, retry", bookId, tries + 1)
                Chapter._schedule(Chapter._retryDelay(tries), function()
                    if cancelled then return end
                    shard("/web/book/chapter/e_0", function(raw, err) onE0(raw, err, tries + 1) end)
                end)
                return
            end
            fail(e0err)
            return
        end
        if e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
            shard("/web/book/chapter/t_0", function(t0, t0err)
                if not t0 then
                    fail(t0err)
                    return
                end
                shard("/web/book/chapter/t_1", function(t1)
                    local plain, decode_err = Protocol.decodeShards(t0, t1 or "")
                    if not plain then
                        fail(decode_err or _("txt 章节解码失败"))
                    else
                        -- 正文只有部分段首带全角空格，剥掉后统一交给章节模板的 text-indent；range 仍按原文。
                        cb(Text.textToBody(Text.stripLineIndent(plain)), nil, plain, "txt")
                    end
                end)
            end)
            return
        end
        shard("/web/book/chapter/e_1", function(e1, e1err)
            if not e1 then
                fail(e1err)
                return
            end
            shard("/web/book/chapter/e_3", function(e3, e3err)
                if not e3 then
                    fail(e3err)
                    return
                end
                local xhtml, decode_err = Protocol.decodeShards(e0, e1, e3)
                if not xhtml then
                    fail(decode_err or _("章节解码失败"))
                elseif not xhtml:find("^%s*<") then
                    -- 无权阅读的付费章：服务端照样 200，回几百字纯文本试读片段（以「...」结尾）。
                    fail(_("该章需购买或付费会员卡，微信读书只返回了试读片段"))
                else
                    cb(xhtml, nil, xhtml, "html")
                end
            end)
        end)
    end
    shard("/web/book/chapter/e_0", function(e0, e0err) onE0(e0, e0err, 0) end)
    return { cancel = cancel }
end

--- 原书脚注是 ``<img class="qqreader-footnote" alt="注文">``，注文只在 alt 里，点了没东西可弹。
--- 图标原样包进 noteref 链接，注文放进 body 末尾的 footnote aside，交给 KOReader 脚注弹窗。
--- 不加 ``<p>``、不动正文文字：段落序号与字偏移不变，划线 range 照旧对得上。
--- 图标尺寸写成行内 style：整书样式表拉取失败 / 缺规则时 CRE 会按 PNG 原始像素×DPI 画成两行高的大方块。
---@param html string
---@return string
local FOOTNOTE_STYLE = "height:0.8em;width:auto;vertical-align:super;border:0"
local function linkFootnotes(html)
    if not html:find("qqreader-footnote", 1, true) then return html end
    local notes = {}
    html = html:gsub("<img%s[^>]*>", function(tag)
        local class = tag:match('class="([^"]*)"') or ""
        local alt = tag:match('alt="([^"]*)"') or ""
        if not class:find("qqreader-footnote", 1, true) then return nil end
        tag = tag:gsub('%sstyle="[^"]*"', ""):gsub("%s*/?>$", ' style="' .. FOOTNOTE_STYLE .. '" />')
        if alt == "" then return tag end
        notes[#notes + 1] = alt
        local n = #notes
        return string.format('<a href="#wr-fn%d" id="wr-fnref%d" epub:type="noteref">%s</a>', n, n, tag)
    end)
    if #notes == 0 then return html end
    local asides = {}
    for i, alt in ipairs(notes) do
        -- alt 已是属性转义过的文本，直接当元素内容合法。
        asides[i] = string.format('<aside id="wr-fn%d" epub:type="footnote">%s</aside>', i, alt)
    end
    local block = table.concat(asides, "\n") .. "\n"
    local last = html:match(".*()</body>")
    if not last then return html .. block end
    return html:sub(1, last - 1) .. block .. html:sub(last)
end

--- 章节载荷：EPUB 是服务端 XHTML 原文（只把图片 / 样式表引用换成本地文件、脚注接上弹窗），TXT 是段落化正文。
---@param bookId string
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: any)
---@return { cancel: fun() }
function Chapter.fetchContentAsync(bookId, chapter, cb)
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return { cancel = function() end }
    end
    local title = chapter.title or string.format(_("第 %d 章"), tonumber(chapter.idx) or 0)
    local cancelled, asset_job = false, nil
    local reader_url = Protocol.readerUrl(bookId, chapter.uid)
    local fetch_job = Chapter.fetchHtmlAsync(bookId, chapter, function(html, err, _source, format)
        if cancelled then return end
        if not html then
            logger.warn("weread chapter fetch", bookId, chapter.idx, err)
            cb(nil, err)
            return
        end
        if format == "txt" then
            -- TXT 正文不含章名（EPUB 原文自带标题），补一个，翻到新章才看得到章名。
            cb({ title = title, html = "<h1>" .. Text.xmlEscape(title) .. "</h1>" .. html })
            return
        end
        asset_job = Assets.localizeAsync(bookId, chapter, html, reader_url, function(done)
            return fetchStyleAsync(bookId, chapter.uid, done)
        end, function(localized)
            if cancelled then return end
            cb({ title = title, document = linkFootnotes(localized) })
        end)
    end)
    return { cancel = function()
            cancelled = true
            fetch_job:cancel()
            if asset_job then asset_job:cancel() end
        end }
end

return Chapter
