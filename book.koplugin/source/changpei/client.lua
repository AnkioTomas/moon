--[[--
长佩文学网 HTTP 客户端（仅异步）。

走官网的匿名 JSON 接口（www.gongzicp.com/webapi）。请求头必须带 `Client: h5`，否则正文是被替换过字的乱码；
正文是 AES 密文，解密放子进程。读得太频繁服务端会要求人机验证（回包 data.check > 1），此时正文被换字打乱，不能用。
登录态是网页 sessionStorage 里的 token，以 `token` 请求头发送（setting.lua 让用户粘贴）；匿名只读免费章，已购 VIP 章要带 token。token 失效回包 code 9996。

@module koplugin.book.source.changpei.client
--]]

local Job = require("workers.job")
local JSON = require("json")
local Mapper = require("source.changpei.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "changpei"
local LOGIN_REQUIRED = 9996

local API = "https://www.gongzicp.com/webapi"
local HEADERS = {
    ["Client"] = "h5",
    ["Referer"] = "https://www.gongzicp.com/",
    ["User-Agent"] = "Mozilla/5.0",
}

--- 已保存的登录 token。
---@return string|nil
function Client.token()
    local token = require("utils.settings").getSource(SOURCE_ID).token
    return type(token) == "string" and token ~= "" and token or nil
end

---@param token string|nil
---@return table<string, string>
local function headers(token)
    local out = { ["token"] = token }
    for key, value in pairs(HEADERS) do out[key] = value end
    return out
end

--- token 显式传入：登录入口要先校验再保存，校验用的新 token 失效不能污染已保存的登录态。
---@param path string
---@param query string
---@param token string|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function get(path, query, token, cb)
    return Request.get(API .. path .. "?" .. query, {
        accept = "application/json",
        headers = headers(token),
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        if wire.code ~= 200 then
            local msg = wire.msg or _("响应无效")
            if wire.code == LOGIN_REQUIRED and token and token == Client.token() then
                msg = require("source.auth").expire(SOURCE_ID, msg)
            end
            cb(nil, msg)
            return
        end
        if token and token == Client.token() then require("source.auth").ok(SOURCE_ID) end
        cb(wire)
    end)
end

---@param keyword string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return get("/search/novels", "page=1&k=" .. Text.urlEncode(keyword), nil, cb)
end

---@param novel_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(novel_id, cb)
    return get("/novel/chapterGetList", "nid=" .. novel_id, Client.token(), cb)
end

--- 校验 token：返回账号信息（nickname 等），失效回调错误。
---@param token string
---@param cb fun(info: table|nil, err: string|nil)
---@return HttpJob
function Client.userAsync(token, cb)
    return get("/user/getUserInfo", "", token, function(wire, err)
        cb(wire and wire.data or nil, err)
    end)
end

--- 一章正文（纯文本，段落以换行分隔）。
---@param _novel_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Client.contentAsync(_novel_id, chapter_id, cb)
    local cancelled, job = false, nil
    job = get("/novel/chapterGetInfo", "cid=" .. chapter_id .. "&server=0", Client.token(), function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        job = Job.run(function()
            local text, reason, kind = Mapper.content(wire)
            return { text = text, err = reason, kind = kind }
        end, {
            name = "changpei_content",
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                if res.text then cb(res.text); return end
                if res.kind == "verify" then
                    cb(nil, _("长佩要求人机验证，请先在浏览器打开 gongzicp.com 阅读一章完成验证"))
                    return
                end
                cb(nil, res.err or _("长佩章节内容为空"), res.kind)
            end,
            on_failed = function(reason) if not cancelled then cb(nil, tostring(reason)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return Client
