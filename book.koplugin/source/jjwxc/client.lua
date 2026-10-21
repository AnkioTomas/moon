--[[--
晋江文学城 HTTP 客户端（仅异步）。

书的元数据、目录、免费章正文走匿名 App JSON 接口（app-cdn.jjwxc.net/androidapi）；
登录态是手机网页的 Cookie，只用于两件事：个人收藏（m.jjwxc.com/my/fav，GBK 的 HTML）与 VIP 章正文
（m.jjwxc.com/vip/<书>/<章>，已购章节才有正文，正文用反爬字体，见 font.lua）。Cookie 失效时网页 302 到登录页。

@module koplugin.book.source.jjwxc.client
--]]

local Charset = require("utils.charset")
local Font = require("source.jjwxc.font")
local JSON = require("json")
local Mapper = require("source.jjwxc.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "jjwxc"
local APP = "https://app-cdn.jjwxc.net/androidapi"
local WEB = "https://m.jjwxc.com"
local APP_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Linux; Android 5.1; Lenovo) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 "
        .. "Chrome/39.0.0.0 Mobile Safari/537.36/JINJIANG-Android/206(Lenovo;android 5.1;Scale/2.0)",
    ["Referer"] = "http://android.jjwxc.net?v=206",
}
local FONT_URL = "https://static.jjwxc.net/tmp/fonts/%s.ttf"
local WEB_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"
-- 接口回包里「该章是 VIP 章」的 code。
local VIP_CODE = 1004

---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

---@param path string
---@param params table<string, any>
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
---@param ratio number|nil 超时倍率，缺省 0.5
local function appGet(path, params, cb, ratio)
    local query = {}
    for key, value in pairs(params) do query[#query + 1] = key .. "=" .. tostring(value) end
    table.sort(query)
    return Request.get(APP .. path .. "?" .. table.concat(query, "&"), {
        accept = "application/json",
        headers = APP_HEADERS,
        timeout = require("http.timeout").net(ratio or 0.5),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        cb(wire)
    end)
end

--- 带登录态取网页，回调 UTF-8 的 HTML。302 到登录页 = Cookie 失效。
---@param path string
---@param cookie string|nil
---@param cb fun(html: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return HttpJob
local function webGet(path, cookie, cb)
    return Request.get(WEB .. path, {
        headers = { Cookie = cookie, ["User-Agent"] = WEB_UA },
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
                cb(nil, cookie == Client.cookie() and require("source.auth").expire(SOURCE_ID, msg) or msg)
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
function Client.favAsync(cookie, cb)
    return webGet("/my/fav", cookie, function(html, err)
        if not html then cb(nil, err); return end
        local rows = Mapper.favRows(html)
        if not rows then cb(nil, _("晋江收藏页无法解析")); return end
        if cookie == Client.cookie() then require("source.auth").ok(SOURCE_ID) end
        cb(rows)
    end)
end

--- 手机榜单页：/rank/naturalmore/<榜单号>，一页按频道分好几节，每节 20 本。
---@param rank_id string
---@param cb fun(sections: table[]|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(rank_id, cb)
    return webGet("/rank/naturalmore/" .. rank_id, nil, function(html, err)
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
function Client.favRemoveAsync(novel_id, cb)
    local cookie = Client.cookie()
    if not cookie then return require("source.base").defer(cb, nil, _("未登录晋江")) end
    return webGet("/my/delBookSure?novelid=" .. novel_id, cookie, function(html, err)
        cb(html and true or nil, err)
    end)
end

---@param keyword string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return appGet("/search", { keyword = Text.urlEncode(keyword), type = 1, page = 1, versionCode = 206 }, cb, 1)
end

---@param novel_id string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(novel_id, cb)
    return appGet("/novelbasicinfo", { novelId = novel_id }, function(wire, err)
        if not wire then cb(nil, err); return end
        if not wire.novelName then cb(nil, wire.message or _("晋江书籍信息为空")); return end
        cb(wire)
    end)
end

---@param novel_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(novel_id, cb)
    return appGet("/chapterList", { novelId = novel_id, more = 0, whole = 1 }, cb)
end

--- 一章正文（纯文本，段落以换行分隔）。App 接口只给免费章；VIP 章在已登录时改走网页（已购才有正文）。
---@param novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil) kind = "unpaid"：Cookie 有效但这章没买
---@return { cancel: fun() }
function Client.contentAsync(novel_id, chapter_id, cb)
    local cancelled, job = false, nil
    job = appGet("/chapterContent", { novelId = novel_id, chapterId = chapter_id }, function(wire, err)
        if cancelled then return end
        if wire and type(wire.content) == "string" and wire.content ~= "" then
            cb(wire.content)
            return
        end
        local cookie = Client.cookie()
        if not (wire and tonumber(wire.code) == VIP_CODE and cookie) then
            cb(nil, err or (wire and wire.message) or _("晋江章节内容为空"))
            return
        end
        job = webGet("/vip/" .. novel_id .. "/" .. chapter_id, cookie, function(html, web_err, kind)
            if cancelled then return end
            local text = html and Mapper.webContent(html)
            if html and not text and html:find('id="contentvars"', 1, true) then
                cb(nil, _("晋江 VIP 章节解密失败"))
                return
            end
            if not text then
                cb(nil, web_err or _("晋江 VIP 章节未购买"), (kind or html) and "unpaid" or nil)
                return
            end
            local font = html:match("jjwxcfont_%w+")
            if not (font and text:find("[\238\239][\128-\191][\128-\191]")) then cb(text); return end
            job = Request.get(FONT_URL:format(font), {
                timeout = require("http.timeout").net(0.5),
            }, function(ttf, font_err)
                if cancelled then return end
                local map = ttf and Font.mapping(ttf)
                if not map then cb(nil, font_err and tostring(font_err) or _("晋江 VIP 章节字体无法解析")); return end
                cb(Font.decode(text, map))
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

--- 这章 VIP 买了没有：true 已购、false 未购、nil 没问出来（未登录 / 网络 / Cookie 失效）。
---@param novel_id string
---@param chapter_id string
---@param cb fun(paid: boolean|nil)
---@return HttpJob|nil
function Client.paidAsync(novel_id, chapter_id, cb)
    local cookie = Client.cookie()
    if not cookie then cb(nil); return nil end
    return webGet("/vip/" .. novel_id .. "/" .. chapter_id, cookie, function(html, _err, kind)
        if kind == "unpaid" then cb(false)
        elseif html and html:find('id="contentvars"', 1, true) then cb(true)
        else cb(nil) end
    end)
end

return Client
