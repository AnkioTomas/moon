--[[--
晋江「网页」协议：手机网页（m.jjwxc.com）+ 登录 Cookie。

Cookie 来自远程管理里的「浏览器登录」，或在电脑浏览器登录后手动粘贴（手机网页登录要过数美验证，设备上做不了）。
能做：个人收藏（/my/fav，GBK 的 HTML）、取消收藏、VIP 章正文（/vip/<书>/<章>，已购才有正文，反爬字体见 font.lua）、
VIP 章购买状态。Cookie 失效时网页 302 到登录页。
榜单页（/rank/…）不要登录，但同样是手机网页，放在这里。

协议接口（protocols/init.lua 按设置选一个协议调用）：`available` / `shelfAsync` / `contentAsync`。

@module koplugin.book.source.jjwxc.protocols.web
--]]

local Charset = require("utils.charset")
local Font = require("source.jjwxc.font")
local Job = require("workers.job")
local Mapper = require("source.jjwxc.mapper")
local Request = require("http.request")
local _ = require("gettext")

local Web = {}

Web.id = "web"

local SOURCE_ID = "jjwxc"
local HOST = "https://m.jjwxc.com"
local FONT_URL = "https://static.jjwxc.net/tmp/fonts/%s.ttf"
local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"

---@return string
function Web.label() return _("网页 Cookie") end

---@return string|nil
function Web.cookie()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

---@return boolean
function Web.available() return Web.cookie() ~= nil end

--- 段评接口（Pc/comment）的登录态：VIP 章节要求，网页协议走 Cookie。
---@return string query
---@return table headers
function Web.commentAuth() return "", { Cookie = Web.cookie() } end

--- 带登录态取网页，回调 UTF-8 的 HTML。302 到登录页 = Cookie 失效。
---@param path string
---@param cookie string|nil
---@param cb fun(html: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return HttpJob
local function get(path, cookie, cb)
    return Request.get(HOST .. path, {
        headers = { Cookie = cookie, ["User-Agent"] = UA },
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err, res)
        if not raw then
            local location = res and tonumber(res.code) == 302 and Request.header(res, "Location")
            if location and not location:find("login", 1, true) then
                -- 跳到非登录页（如未购买章节的订阅页）说明 Cookie 有效
                cb(nil, _("晋江 VIP 章节未购买"), "unpaid")
            elseif location then
                -- 校验新 Cookie 时不能污染已保存的登录态。
                local msg = _("晋江登录已失效")
                cb(nil, cookie == Web.cookie() and require("source.auth").expire(SOURCE_ID, msg) or msg)
            else
                cb(nil, err and tostring(err) or _("请求失败"))
            end
            return
        end
        local html, charset = Charset.toUtf8(raw, Request.header(res, "Content-Type"))
        if not html then cb(nil, charset); return end
        cb(html)
    end)
end

--- 拉个人收藏（一页列全）。cookie 显式传入：登录入口要先校验再保存。
---@param cookie string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Web.favAsync(cookie, cb)
    return get("/my/fav", cookie, function(html, err)
        if not html then cb(nil, err); return end
        local rows = Mapper.favRows(html)
        if not rows then cb(nil, _("晋江收藏页无法解析")); return end
        if cookie == Web.cookie() then require("source.auth").ok(SOURCE_ID) end
        cb(rows)
    end)
end

---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Web.shelfAsync(cb)
    return Web.favAsync(Web.cookie(), cb)
end

--- 手机榜单页：/rank/naturalmore/<榜单号>，一页按频道分好几节，每节 20 本。
---@param rank_id string
---@param cb fun(sections: table[]|nil, err: string|nil)
---@return HttpJob
function Web.rankAsync(rank_id, cb)
    return get("/rank/naturalmore/" .. rank_id, nil, function(html, err)
        if not html then cb(nil, err); return end
        local sections = Mapper.rankSections(html)
        if #sections == 0 then cb(nil, _("晋江榜单无法解析")); return end
        cb(sections)
    end)
end

--- 取消收藏。网页是「确认页 → /my/delBookSure」两步，这里直接走第二步。
---@param novel_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Web.favRemoveAsync(novel_id, cb)
    local cookie = Web.cookie()
    if not cookie then return require("source.base").defer(cb, nil, _("未登录晋江")) end
    return get("/my/delBookSure?novelid=" .. novel_id, cookie, function(html, err)
        cb(html and true or nil, err)
    end)
end

--- 这章 VIP 买了没有：true 已购、false 未购、nil 没问出来（未登录 / 网络 / Cookie 失效）。
---@param novel_id string
---@param chapter_id string
---@param cb fun(paid: boolean|nil)
---@return HttpJob|nil
function Web.paidAsync(novel_id, chapter_id, cb)
    local cookie = Web.cookie()
    if not cookie then cb(nil); return nil end
    return get("/vip/" .. novel_id .. "/" .. chapter_id, cookie, function(html, _err, kind)
        if kind == "unpaid" then cb(false)
        elseif html and html:find('id="contentvars"', 1, true) then cb(true)
        else cb(nil) end
    end)
end

--- 反爬字体的私有区字符映射回真字：下字体、解析映射都放子进程。
---@param text string
---@param font string
---@param cancelled fun(): boolean
---@param cb fun(text: string|nil, err: string|nil)
---@return { cancel: fun() }
local function decodeFont(text, font, cancelled, cb)
    local job
    job = Request.get(FONT_URL:format(font), {
        timeout = require("http.timeout").net(0.5),
    }, function(ttf, font_err)
        if cancelled() then return end
        if not ttf then cb(nil, font_err and tostring(font_err) or _("晋江 VIP 章节字体无法解析")); return end
        job = Job.run(function()
            local map = Font.mapping(ttf)
            return { text = map and Font.decode(text, map) }
        end, {
            name = "jjwxc_font",
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled() then return end
                if res.text then cb(res.text) else cb(nil, _("晋江 VIP 章节字体无法解析")) end
            end,
            on_failed = function(err) if not cancelled() then cb(nil, tostring(err)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function() job:cancel() end }
end

--- VIP 章正文（纯文本，段落以换行分隔）：网页只有已购章节才有正文。
---@param novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Web.contentAsync(novel_id, chapter_id, cb)
    local cancelled, job = false, nil
    local function isCancelled() return cancelled end
    job = get("/vip/" .. novel_id .. "/" .. chapter_id, Web.cookie(), function(html, web_err, kind)
        if cancelled then return end
        if not html then
            cb(nil, web_err or _("晋江 VIP 章节未购买"), kind and "unpaid" or nil)
            return
        end
        -- AES 解密与字体解析都是纯 Lua 重活，放子进程，免得卡 UI
        job = Job.run(function() local text, why = Mapper.webContent(html); return { text = text, why = why } end, {
            name = "jjwxc_vip",
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                local text = res.text
                if not text then
                    if html:find('id="contentvars"', 1, true) then
                        local scripts = {}
                        for src in html:gmatch('<script[^>]-src="([^"]*)"') do scripts[#scripts + 1] = src end
                        require("utils.log").warn("jjwxc vip decrypt failed", novel_id, chapter_id, res.why,
                            "scripts", table.concat(scripts, " "),
                            "contentvars", (html:match('id="contentvars".-</div>') or "none"):sub(1, 8000))
                        cb(nil, _("晋江 VIP 章节解密失败"))
                    else
                        cb(nil, _("晋江 VIP 章节未购买"), "unpaid")
                    end
                    return
                end
                local font = html:match("jjwxcfont_%w+")
                if not (font and text:find("[\238\239][\128-\191][\128-\191]")) then cb(text); return end
                job = decodeFont(text, font, isCancelled, cb)
            end,
            on_failed = function(err) if not cancelled then cb(nil, tostring(err)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return Web
