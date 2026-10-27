--[[--
晋江文学城 HTTP 客户端（仅异步）：匿名 App JSON 接口（app-cdn.jjwxc.net/androidapi）。

书的元数据、目录、免费章正文都不要登录。VIP 章正文需要登录态，交给 protocols/ 里用户选定的协议
（web 网页 Cookie / app 账号 token，二选一，见 protocols/init.lua）。

@module koplugin.book.source.jjwxc.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local APP = "https://app-cdn.jjwxc.net/androidapi"
local APP_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Linux; Android 5.1; Lenovo) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 "
        .. "Chrome/39.0.0.0 Mobile Safari/537.36/JINJIANG-Android/206(Lenovo;android 5.1;Scale/2.0)",
    ["Referer"] = "http://android.jjwxc.net?v=206",
}
-- 接口回包里「该章是 VIP 章」的 code。
local VIP_CODE = 1004

---@param path string
---@param params table<string, any>
---@param cb fun(wire: table|nil, err: string|nil)
---@param ratio number|nil 超时倍率，缺省 0.5
---@return HttpJob
local function appGet(path, params, cb, ratio, cache_ttl)
    local query = {}
    for key, value in pairs(params) do query[#query + 1] = key .. "=" .. tostring(value) end
    table.sort(query)
    return Request.get(APP .. path .. "?" .. table.concat(query, "&"), {
        accept = "application/json",
        headers = APP_HEADERS,
        timeout = require("http.timeout").net(ratio or 0.5),
        cache_ttl = cache_ttl,
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        cb(wire)
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

--- 一章正文（纯文本，段落以换行分隔）。匿名接口只给免费章；VIP 章在已登录时交给选定协议。
---@param novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil) kind = "unpaid"：登录态有效但这章没买
---@return { cancel: fun() }
function Client.contentAsync(novel_id, chapter_id, cb)
    local cancelled, job = false, nil
    job = appGet("/chapterContent", { novelId = novel_id, chapterId = chapter_id }, function(wire, err)
        if cancelled then return end
        if wire and type(wire.content) == "string" and wire.content ~= "" then
            cb(wire.content)
            return
        end
        local protocol = require("source.jjwxc.protocols").current()
        if not (wire and tonumber(wire.code) == VIP_CODE and protocol) then
            cb(nil, err or (wire and wire.message) or _("晋江章节内容为空"))
            return
        end
        job = protocol.contentAsync(novel_id, chapter_id, cb)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return Client
